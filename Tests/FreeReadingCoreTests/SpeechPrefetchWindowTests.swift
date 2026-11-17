import XCTest
@testable import FreeReadingCore

/// 窗口直接驱动 Controller 的合成循环与缓存保护，不使用真实 TTS 或等待时钟。
final class SpeechPrefetchWindowTests: XCTestCase {
    private let session = PlaybackCoordinator.Session(bookID: "book", addedAt: Date(timeIntervalSince1970: 100))

    func testStopsAfterPlaybackReserveInsteadOfPreparingWholeChapter() {
        var window = SpeechPrefetchWindow()
        let token = window.advance(session: session, voiceID: "voice", index: 0, sentenceCount: 100_000, speed: 1)
        XCTAssertEqual(window.nextTarget, 1)
        XCTAssertTrue(window.record(index: 1, duration: 4, ticket: token))
        XCTAssertEqual(window.nextTarget, 2)
        XCTAssertTrue(window.record(index: 2, duration: 8, ticket: token))
        XCTAssertNil(window.nextTarget)
        XCTAssertEqual(window.retainedIndices, [1, 2])
    }

    func testNaturalAdvancePreservesInFlightTicketAndFutureClips() {
        var window = SpeechPrefetchWindow()
        let first = window.advance(session: session, voiceID: "voice", index: 0, sentenceCount: 20, speed: 1)
        _ = window.record(index: 1, duration: 4, ticket: first)
        _ = window.record(index: 2, duration: 8, ticket: first)
        let continued = window.advance(session: session, voiceID: "voice", index: 1, sentenceCount: 20, speed: 1)
        XCTAssertEqual(first, continued)
        XCTAssertTrue(window.accepts(first))
        XCTAssertEqual(window.nextTarget, 3)
        XCTAssertTrue(window.record(index: 3, duration: 5, ticket: first))
        XCTAssertNil(window.nextTarget)
        XCTAssertEqual(window.retainedIndices, [2, 3])
    }

    func testShortSentencesAndDoubleSpeedStillHaveBoundedLookahead() {
        var window = SpeechPrefetchWindow()
        let token = window.advance(session: session, voiceID: "voice", index: 0, sentenceCount: 100, speed: 2)
        for index in 1...12 {
            XCTAssertEqual(window.nextTarget, index)
            XCTAssertTrue(window.record(index: index, duration: 0.4, ticket: token))
        }
        XCTAssertNil(window.nextTarget)
        _ = window.advance(session: session, voiceID: "voice", index: 1, sentenceCount: 100, speed: 2)
        XCTAssertEqual(window.nextTarget, 13)
    }

    func testSpeedChangesRecalculateSameWindowFromMediaDurations() {
        var window = SpeechPrefetchWindow()
        let token = window.advance(session: session, voiceID: "voice", index: 0, sentenceCount: 9, speed: 1)
        _ = window.record(index: 1, duration: 12, ticket: token)
        XCTAssertNil(window.nextTarget)
        XCTAssertEqual(window.advance(session: session, voiceID: "voice", index: 0, sentenceCount: 9, speed: 2), token)
        XCTAssertEqual(window.nextTarget, 2)
        _ = window.record(index: 2, duration: 12, ticket: token)
        XCTAssertNil(window.nextTarget)
    }

    func testExplicitResetRejectsOldCompletionForSameBookAndVoice() {
        var window = SpeechPrefetchWindow()
        let old = window.advance(session: session, voiceID: "voice", index: 0, sentenceCount: 9, speed: 1)
        window.reset()
        let new = window.advance(session: session, voiceID: "voice", index: 0, sentenceCount: 9, speed: 1)
        XCTAssertNotEqual(old, new)
        XCTAssertFalse(window.record(index: 1, duration: 4, ticket: old))
        XCTAssertEqual(window.nextTarget, 1)
    }

    func testVoiceReimportAndBackwardNavigationInvalidateOwnership() {
        var window = SpeechPrefetchWindow()
        let old = window.advance(session: session, voiceID: "first", index: 2, sentenceCount: 9, speed: 1)
        let voice = window.advance(session: session, voiceID: "second", index: 2, sentenceCount: 9, speed: 1)
        XCTAssertNotEqual(old, voice)
        XCTAssertFalse(window.accepts(old))
        let newer = PlaybackCoordinator.Session(bookID: session.bookID, addedAt: session.addedAt.addingTimeInterval(1))
        let imported = window.advance(session: newer, voiceID: "second", index: 2, sentenceCount: 9, speed: 1)
        XCTAssertNotEqual(voice, imported)
        XCTAssertFalse(window.accepts(voice))
        let backwards = window.advance(session: newer, voiceID: "second", index: 0, sentenceCount: 9, speed: 1)
        XCTAssertNotEqual(imported, backwards)
    }

    func testBookEndInvalidDurationsAndLateCurrentSentenceDoNotInventWork() {
        var window = SpeechPrefetchWindow()
        let token = window.advance(session: session, voiceID: "voice", index: 1, sentenceCount: 3, speed: .nan)
        XCTAssertFalse(window.record(index: 2, duration: .nan, ticket: token))
        XCTAssertFalse(window.record(index: 1, duration: 2, ticket: token))
        XCTAssertFalse(window.record(index: 3, duration: 2, ticket: token))
        XCTAssertEqual(window.nextTarget, 2)
        _ = window.record(index: 2, duration: 2, ticket: token)
        XCTAssertNil(window.nextTarget)
        _ = window.advance(session: session, voiceID: "voice", index: 2, sentenceCount: 3, speed: 1)
        XCTAssertFalse(window.record(index: 2, duration: 2, ticket: token))
        XCTAssertNil(window.nextTarget)
    }

    func testNaturalAdvanceKeepsTheRunningWorkAndDoesNotStartAnotherWorker() throws {
        var window = SpeechPrefetchWindow()
        _ = window.advance(session: session, voiceID: "voice", index: 0, sentenceCount: 30, speed: 1)
        let work = try XCTUnwrap(window.beginWork())
        XCTAssertNil(window.beginWork())
        _ = window.advance(session: session, voiceID: "voice", index: 1, sentenceCount: 30, speed: 2)
        XCTAssertTrue(window.accepts(work))
        XCTAssertNil(window.beginWork(), "自然换句和倍速调整不能重复启动同一个补充循环")
        XCTAssertTrue(window.record(index: 2, duration: 3, ticket: work.ticket))
        XCTAssertTrue(window.endWork(work))
    }

    func testBackwardSeekCanReplaceOldWorkBeforeItsDelayedCleanup() throws {
        var window = SpeechPrefetchWindow()
        // 模拟定位完成前倍速操作曾用旧快照建立窗口；回跳必须立即开始新窗口。
        _ = window.advance(session: session, voiceID: "voice", index: 10, sentenceCount: 30, speed: 2)
        let old = try XCTUnwrap(window.beginWork())
        _ = window.advance(session: session, voiceID: "voice", index: 5, sentenceCount: 30, speed: 2)
        let new = try XCTUnwrap(window.beginWork())
        XCTAssertFalse(window.accepts(old))
        XCTAssertFalse(window.endWork(old), "旧 Task 的迟到退出不得清除新 Task 句柄")
        XCTAssertTrue(window.accepts(new))
        XCTAssertEqual(window.nextTarget, 6)
        XCTAssertTrue(window.record(index: 6, duration: 24, ticket: new.ticket))
        XCTAssertNil(window.nextTarget)
        XCTAssertTrue(window.endWork(new))
    }

    func testRetryWithinSameWindowHasDistinctTaskOwnership() throws {
        var window = SpeechPrefetchWindow()
        _ = window.advance(session: session, voiceID: "voice", index: 0, sentenceCount: 9, speed: 1)
        let old = try XCTUnwrap(window.beginWork())
        XCTAssertTrue(window.endWork(old))
        let retry = try XCTUnwrap(window.beginWork())
        XCTAssertEqual(old.ticket, retry.ticket)
        XCTAssertNotEqual(old, retry)
        XCTAssertFalse(window.endWork(old))
        XCTAssertTrue(window.accepts(retry))
        window.reset()
        XCTAssertFalse(window.accepts(retry))
        XCTAssertFalse(window.endWork(retry))
    }

    func testExhaustedWindowDoesNotInventAWorker() {
        var window = SpeechPrefetchWindow()
        XCTAssertNil(window.beginWork())
        _ = window.advance(session: session, voiceID: "voice", index: 2, sentenceCount: 3, speed: 1)
        XCTAssertNil(window.beginWork())
    }
}
