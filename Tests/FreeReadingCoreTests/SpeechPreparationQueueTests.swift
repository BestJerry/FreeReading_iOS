import XCTest
@testable import FreeReadingCore

/// 使用可控的真实异步生产闭包检验实际队列，不依赖系统 TTS 的速度或设备声音。
@MainActor
final class SpeechPreparationQueueTests: XCTestCase {
    private typealias Queue = SpeechPreparationQueue<String, String>
    @MainActor private final class Gate {
        private var result: Result<String, Error>?
        private var continuation: CheckedContinuation<String, Error>?
        func value() async throws -> String {
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func finish(_ value: String) { complete(.success(value)) }
        func fail(_ error: Error) { complete(.failure(error)) }
        private func complete(_ result: Result<String, Error>) {
            self.result = result
            let pending = continuation; continuation = nil
            pending?.resume(with: result)
        }
    }

    private func waitForConsumers(_ count: Int, key: String, in queue: Queue) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while queue.waitingConsumers(for: key) != count {
            guard ContinuousClock.now < deadline else {
                XCTFail("\(key) 的消费者数量未到达 \(count)")
                throw CancellationError()
            }
            await Task.yield()
        }
    }
    private func assertCancelled(_ result: Result<String, Error>, file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case .success: XCTFail("已取消请求不能发布成功结果", file: file, line: line)
        case .failure(let error): XCTAssertTrue(error is CancellationError, file: file, line: line)
        }
    }

    func testPlayingAdoptsInFlightPrefetchAndCancellingPrefetchWaiterDoesNotResynthesize() async throws {
        let queue = Queue(), gate = Gate()
        let started = expectation(description: "预取开始")
        var count = 0
        let prefetch = Task { try await queue.value(for: "next", priority: .prefetch) {
            count += 1; started.fulfill(); return try await gate.value()
        } }
        await fulfillment(of: [started], timeout: 3)
        let playback = Task { try await queue.value(for: "next", priority: .playback) {
            count += 1; return "不应重复合成"
        } }
        try await waitForConsumers(2, key: "next", in: queue)
        prefetch.cancel()
        try await waitForConsumers(1, key: "next", in: queue)
        assertCancelled(await prefetch.result)
        gate.finish("同一次合成")
        let result1 = try await playback.value
        XCTAssertEqual(result1, "同一次合成")
        XCTAssertEqual(count, 1)
    }

    func testRepeatedShortSentenceHandoffsGenerateEverySentenceOnlyOnce() async throws {
        let queue = Queue()
        var generated: [String: Int] = [:]
        for index in 0..<8 {
            let key = "sentence-\(index)", gate = Gate()
            let prefetch = Task { try await queue.value(for: key, priority: .prefetch) {
                generated[key, default: 0] += 1
                return try await gate.value()
            } }
            try await waitForConsumers(1, key: key, in: queue)
            let playback = Task { try await queue.value(for: key) {
                generated[key, default: 0] += 1; return "不应执行第二次合成"
            } }
            try await waitForConsumers(2, key: key, in: queue)
            gate.finish(key)
            let result2 = try await playback.value
            XCTAssertEqual(result2, key)
            let result3 = try await prefetch.value
            XCTAssertEqual(result3, key)
        }
        XCTAssertEqual(generated.count, 8)
        XCTAssertTrue(generated.values.allSatisfy { $0 == 1 })
    }

    func testQueuedPlaybackOvertakesEarlierPrefetchWithoutInterruptingCurrentPlayback() async throws {
        let queue = Queue(), firstGate = Gate(), urgentGate = Gate(), backgroundGate = Gate()
        var order: [String] = []
        let firstStarted = expectation(description: "当前播放开始")
        let urgentStarted = expectation(description: "播放优先开始")
        let backgroundStarted = expectation(description: "之后才预取")
        let first = Task { try await queue.value(for: "first") {
            order.append("first"); firstStarted.fulfill(); return try await firstGate.value()
        } }
        await fulfillment(of: [firstStarted], timeout: 3)
        let background = Task { try await queue.value(for: "background", priority: .prefetch) {
            order.append("background"); backgroundStarted.fulfill(); return try await backgroundGate.value()
        } }
        try await waitForConsumers(1, key: "background", in: queue)
        let urgent = Task { try await queue.value(for: "urgent") {
            order.append("urgent"); urgentStarted.fulfill(); return try await urgentGate.value()
        } }
        try await waitForConsumers(1, key: "urgent", in: queue)
        XCTAssertEqual(order, ["first"])
        firstGate.finish("first")
        _ = try await first.value
        await fulfillment(of: [urgentStarted], timeout: 3)
        XCTAssertEqual(order, ["first", "urgent"])
        urgentGate.finish("urgent"); _ = try await urgent.value
        await fulfillment(of: [backgroundStarted], timeout: 3)
        backgroundGate.finish("background"); _ = try await background.value
        XCTAssertEqual(order, ["first", "urgent", "background"])
    }

    func testUnrelatedForegroundPreemptsPrefetchButWaitsForOldProducerToExit() async throws {
        let queue = Queue(), oldGate = Gate(), urgentGate = Gate()
        let oldStarted = expectation(description: "旧预取开始"), urgentStarted = expectation(description: "前台开始")
        var urgentHasStarted = false
        let old = Task { try await queue.value(for: "unrelated", priority: .prefetch) {
            oldStarted.fulfill(); return try await oldGate.value() // 故意忽略取消，模拟迟到的系统回调。
        } }
        await fulfillment(of: [oldStarted], timeout: 3)
        let urgent = Task { try await queue.value(for: "playing") {
            urgentHasStarted = true; urgentStarted.fulfill(); return try await urgentGate.value()
        } }
        try await waitForConsumers(1, key: "playing", in: queue)
        assertCancelled(await old.result)
        XCTAssertFalse(urgentHasStarted, "旧合成器尚未退出，不能让两个生产任务重叠")
        oldGate.finish("迟到旧音频")
        await fulfillment(of: [urgentStarted], timeout: 3)
        urgentGate.finish("正确前台音频")
        let result4 = try await urgent.value
        XCTAssertEqual(result4, "正确前台音频")
    }

    func testCancelAllThenImmediatelyRequestingSameKeyRejectsOldCompletion() async throws {
        let queue = Queue(), oldGate = Gate(), newGate = Gate()
        let oldStarted = expectation(description: "旧代次开始"), newStarted = expectation(description: "新代次开始")
        var newCount = 0
        let old = Task { try await queue.value(for: "same") { oldStarted.fulfill(); return try await oldGate.value() } }
        await fulfillment(of: [oldStarted], timeout: 3)
        queue.cancelAll()
        assertCancelled(await old.result)
        let newer = Task { try await queue.value(for: "same") {
            newCount += 1; newStarted.fulfill(); return try await newGate.value()
        } }
        try await waitForConsumers(1, key: "same", in: queue)
        XCTAssertEqual(newCount, 0)
        oldGate.finish("已取消的旧结果")
        await fulfillment(of: [newStarted], timeout: 3)
        newGate.finish("新结果")
        let result5 = try await newer.value
        XCTAssertEqual(result5, "新结果")
        XCTAssertEqual(newCount, 1)
        XCTAssertEqual(queue.waitingConsumers(for: "same"), 0)
    }

    func testCancellingQueuedConsumerNeverStartsItsProducer() async throws {
        let queue = Queue(), gate = Gate()
        let started = expectation(description: "当前开始")
        var queuedStarted = false
        let current = Task { try await queue.value(for: "current") { started.fulfill(); return try await gate.value() } }
        await fulfillment(of: [started], timeout: 3)
        let cancelled = Task { try await queue.value(for: "queued", priority: .prefetch) { queuedStarted = true; return "错误" } }
        try await waitForConsumers(1, key: "queued", in: queue)
        cancelled.cancel(); assertCancelled(await cancelled.result)
        gate.finish("当前结果"); _ = try await current.value
        XCTAssertFalse(queuedStarted)
    }

    func testFailureFansOutAndNextRequestCanRetry() async throws {
        struct SynthesisFailure: Error {}
        let queue = Queue(), gate = Gate()
        var attempts = 0
        let first = Task { try await queue.value(for: "retry") { attempts += 1; return try await gate.value() } }
        try await waitForConsumers(1, key: "retry", in: queue)
        let joined = Task { try await queue.value(for: "retry") { attempts += 1; return "不应执行" } }
        try await waitForConsumers(2, key: "retry", in: queue)
        gate.fail(SynthesisFailure())
        for result in [await first.result, await joined.result] {
            if case .failure(let error) = result { XCTAssertTrue(error is SynthesisFailure) }
            else { XCTFail("合成失败不能发布成功") }
        }
        let retried = try await queue.value(for: "retry") { attempts += 1; return "重试成功" }
        XCTAssertEqual(retried, "重试成功"); XCTAssertEqual(attempts, 2)
    }

    func testPromotingQueuedPrefetchChangesItsSchedulingPriority() async throws {
        let queue = Queue(), gate = Gate()
        let started = expectation(description: "当前开始")
        var order: [String] = []
        let current = Task { try await queue.value(for: "current") { started.fulfill(); return try await gate.value() } }
        await fulfillment(of: [started], timeout: 3)
        let earlier = Task { try await queue.value(for: "earlier", priority: .prefetch) { order.append("earlier"); return "earlier" } }
        try await waitForConsumers(1, key: "earlier", in: queue)
        let later = Task { try await queue.value(for: "later", priority: .prefetch) { order.append("later"); return "later" } }
        try await waitForConsumers(1, key: "later", in: queue)
        let playing = Task { try await queue.value(for: "later") { XCTFail("不应重复生产"); return "错误" } }
        try await waitForConsumers(2, key: "later", in: queue)
        gate.finish("当前完成"); _ = try await current.value
        let result6 = try await playing.value
        XCTAssertEqual(result6, "later")
        _ = try await later.value; _ = try await earlier.value
        XCTAssertEqual(order, ["later", "earlier"])
    }

    func testRemovingOneBookDoesNotCancelAnotherBookProducer() async throws {
        let queue = Queue(), gate = Gate()
        let started = expectation(description: "另一本书开始")
        var removedBookStarted = false
        let current = Task { try await queue.value(for: "book-B/current") { started.fulfill(); return try await gate.value() } }
        await fulfillment(of: [started], timeout: 3)
        let removed = Task { try await queue.value(for: "book-A/next", priority: .prefetch) { removedBookStarted = true; return "错误" } }
        try await waitForConsumers(1, key: "book-A/next", in: queue)
        queue.cancel { $0.hasPrefix("book-A/") }
        assertCancelled(await removed.result)
        gate.finish("B继续")
        let result7 = try await current.value
        XCTAssertEqual(result7, "B继续")
        XCTAssertFalse(removedBookStarted)
    }
}
