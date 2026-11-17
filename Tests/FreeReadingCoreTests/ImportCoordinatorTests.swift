import XCTest
@testable import FreeReadingCore

final class ImportCoordinatorTests: XCTestCase {
    private actor Attempts {
        var count = 0
        func next() -> Int { count += 1; return count }
    }
    private actor ImportGate {
        var jobs: [String: CheckedContinuation<SpeechBook, Error>] = [:]
        var progress: [String: @Sendable (ImportProgress) -> Void] = [:]
        func run(_ url: URL, report: @escaping @Sendable (ImportProgress) -> Void, started: XCTestExpectation) async throws -> SpeechBook {
            try await withCheckedThrowingContinuation { continuation in
                jobs[url.lastPathComponent] = continuation
                progress[url.lastPathComponent] = report
                started.fulfill()
            }
        }
        func finish(_ name: String, result: Result<SpeechBook, Error>) { jobs.removeValue(forKey: name)?.resume(with: result) }
        func report(_ name: String) { progress[name]?(ImportProgress(stage: .indexing, completed: 99, total: 100)) }
    }
    private static func book(_ title: String) -> SpeechBook {
        SpeechBook(record: BookRecord(id: title, title: title), chapters: [], sections: [], sentences: [], contents: [])
    }

    @MainActor
    func testReplacementRejectsOldResultAndProgress() async {
        let gate = ImportGate()
        let starts = expectation(description: "both imports started"); starts.expectedFulfillmentCount = 2
        let settled = expectation(description: "both workers exited"); settled.expectedFulfillmentCount = 2
        let coordinator = ImportCoordinator { url, report in try await gate.run(url, report: report, started: starts) }
        var imported: [String] = []
        coordinator.onImported = { book, _ in imported.append(book.record.title) }
        coordinator.onSettled = { _, _ in settled.fulfill() }
        coordinator.begin(URL(fileURLWithPath: "/tmp/old.epub"))
        // Let the old worker enter its operation before replacing it.
        await Task.yield()
        coordinator.begin(URL(fileURLWithPath: "/tmp/new.epub"))
        await fulfillment(of: [starts], timeout: 3)
        await gate.report("old.epub")
        await gate.finish("old.epub", result: .success(Self.book("old")))
        await gate.finish("new.epub", result: .success(Self.book("new")))
        await fulfillment(of: [settled], timeout: 3)
        XCTAssertEqual(imported, ["new"])
        XCTAssertEqual(coordinator.state.phase, .completed)
        XCTAssertNil(coordinator.state.progress)
        XCTAssertEqual(coordinator.state.sourceURL?.lastPathComponent, "new.epub")
    }

    @MainActor
    func testCancellationDoesNotPublishLateSuccessOrCleanSourceBeforeWorkerExits() async {
        let gate = ImportGate()
        let started = expectation(description: "started")
        let settled = expectation(description: "worker exited")
        let coordinator = ImportCoordinator { url, report in try await gate.run(url, report: report, started: started) }
        var didImport = false
        var didSettle = false
        coordinator.onImported = { _, _ in didImport = true }
        coordinator.onSettled = { _, _ in didSettle = true; settled.fulfill() }
        coordinator.begin(URL(fileURLWithPath: "/tmp/cancel.epub"))
        await fulfillment(of: [started], timeout: 3)
        coordinator.cancel()
        XCTAssertFalse(coordinator.state.isImporting)
        XCTAssertFalse(didSettle)
        await gate.finish("cancel.epub", result: .success(Self.book("cancel")))
        await fulfillment(of: [settled], timeout: 3)
        XCTAssertFalse(didImport)
        XCTAssertEqual(coordinator.state.phase, .cancelled)
    }

    @MainActor
    func testFailureKeepsSourceAndRetryUsesNewRequest() async {
        struct Failure: Error {}
        let starts = expectation(description: "first"); let retried = expectation(description: "retry")
        let failed = expectation(description: "failed"); let completed = expectation(description: "completed")
        let attempts = Attempts()
        let coordinator = ImportCoordinator { _, _ in
            let attempt = await attempts.next()
            if attempt == 1 { starts.fulfill(); throw Failure() }
            retried.fulfill(); return Self.book("retry")
        }
        coordinator.onStateChange = { state in
            if state.phase == .failed { failed.fulfill() }
            if state.phase == .completed { completed.fulfill() }
        }
        let url = URL(fileURLWithPath: "/tmp/retry.epub")
        coordinator.begin(url)
        let first = coordinator.state.requestID
        await fulfillment(of: [starts, failed], timeout: 3)
        XCTAssertTrue(coordinator.state.canRetry)
        XCTAssertEqual(coordinator.state.sourceURL, url)
        coordinator.retry()
        XCTAssertNotEqual(coordinator.state.requestID, first)
        await fulfillment(of: [retried, completed], timeout: 3)
        XCTAssertFalse(coordinator.state.canRetry)
    }

    @MainActor
    func testDuplicateOpenWhileImportingDoesNotStartSecondWorker() async {
        let gate = ImportGate()
        let started = expectation(description: "only one worker")
        let settled = expectation(description: "settled")
        let coordinator = ImportCoordinator { url, report in try await gate.run(url, report: report, started: started) }
        coordinator.onSettled = { _, _ in settled.fulfill() }
        let url = URL(fileURLWithPath: "/tmp/same.epub")
        coordinator.begin(url); let id = coordinator.state.requestID
        coordinator.begin(url)
        XCTAssertEqual(coordinator.state.requestID, id)
        await fulfillment(of: [started], timeout: 3)
        await gate.finish("same.epub", result: .success(Self.book("same")))
        await fulfillment(of: [settled], timeout: 3)
    }

    @MainActor
    func testReplacingFailedShareSettlesSourceButRetryKeepsIt() async {
        struct Failure: Error {}
        let finished = expectation(description: "new source finished")
        let coordinator = ImportCoordinator { url, _ in
            if url.lastPathComponent == "shared.epub" { throw Failure() }
            return Self.book("new")
        }
        var discarded: [URL] = []
        coordinator.onSettled = { url, outcome in
            if outcome == .cancelled { discarded.append(url) }
            if outcome == .imported { finished.fulfill() }
        }
        let firstFailed = expectation(description: "first failure")
        coordinator.onStateChange = { state in
            if state.phase == .failed { firstFailed.fulfill() }
        }
        let source = URL(fileURLWithPath: "/tmp/shared.epub")
        coordinator.begin(source)
        await fulfillment(of: [firstFailed], timeout: 3)
        let retryFailed = expectation(description: "retry failure")
        coordinator.onStateChange = { if $0.phase == .failed { retryFailed.fulfill() } }
        coordinator.retry()
        await fulfillment(of: [retryFailed], timeout: 3)
        XCTAssertTrue(discarded.isEmpty)
        coordinator.begin(URL(fileURLWithPath: "/tmp/new.epub"))
        XCTAssertEqual(discarded, [source])
        await fulfillment(of: [finished], timeout: 3)
    }
}
