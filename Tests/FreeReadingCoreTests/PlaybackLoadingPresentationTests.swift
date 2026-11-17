import XCTest
import Combine
@testable import FreeReadingCore

final class PlaybackLoadingPresentationTests: XCTestCase {
    private actor Delay {
        var waiters: [CheckedContinuation<Void, Never>] = []
        var onStart: XCTestExpectation?
        init(onStart: XCTestExpectation) { self.onStart = onStart }
        func wait() async {
            await withCheckedContinuation { continuation in
                waiters.append(continuation); onStart?.fulfill()
            }
        }
        func release() { let values = waiters; waiters.removeAll(); values.forEach { $0.resume() } }
    }

    @MainActor
    func testHotCacheOrBriefSentenceHandoffNeverShowsBuffering() async {
        let started = expectation(description: "delay started")
        let delay = Delay(onStart: started)
        let value = PlaybackLoadingPresentation(wait: { await delay.wait() })
        value.update(isPreparing: true, wantsPlayback: true)
        XCTAssertFalse(value.isVisible)
        await fulfillment(of: [started], timeout: 2)
        value.update(isPreparing: false, wantsPlayback: true)
        await delay.release()
        await Task.yield()
        XCTAssertFalse(value.isVisible)
    }

    @MainActor
    func testRealWaitShowsIndicatorAndCompletionImmediatelyClearsIt() async {
        let started = expectation(description: "delay started")
        let delay = Delay(onStart: started)
        let value = PlaybackLoadingPresentation(wait: { await delay.wait() })
        let shown = expectation(description: "indicator shown")
        let observer = value.$isVisible.sink { if $0 { shown.fulfill() } }
        defer { observer.cancel() }
        value.update(isPreparing: true, wantsPlayback: true)
        // A periodic snapshot must not push the deadline back.
        value.update(isPreparing: true, wantsPlayback: true)
        await fulfillment(of: [started], timeout: 2)
        await delay.release()
        await fulfillment(of: [shown], timeout: 2)
        XCTAssertTrue(value.isVisible)
        value.update(isPreparing: false, wantsPlayback: true)
        XCTAssertFalse(value.isVisible)
    }

    @MainActor
    func testPauseAndDismissRejectOldWaitingCompletion() async {
        let started = expectation(description: "delay started")
        let delay = Delay(onStart: started)
        let value = PlaybackLoadingPresentation(wait: { await delay.wait() })
        value.update(isPreparing: true, wantsPlayback: true)
        await fulfillment(of: [started], timeout: 2)
        value.update(isPreparing: true, wantsPlayback: false)
        value.cancel()
        await delay.release()
        await Task.yield()
        XCTAssertFalse(value.isVisible)
        value.update(isPreparing: true, wantsPlayback: false)
        XCTAssertFalse(value.isVisible)
    }
}
