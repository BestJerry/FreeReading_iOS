import XCTest
@testable import FreeReadingCore

/// 这些规则直接裁决 PlaybackController 的真实播放器安装与自动播放，而非另一份模拟实现。
final class PlaybackCoordinatorTests: XCTestCase {
    private let importedAt = Date(timeIntervalSince1970: 100)

    private func coordinator() -> PlaybackCoordinator {
        var value = PlaybackCoordinator()
        value.open(bookID: "first", addedAt: importedAt, sentenceCount: 8)
        return value
    }

    func testPauseDuringPreparationWinsWhenAudioArrives() throws {
        var value = coordinator()
        let request = try XCTUnwrap(value.prepare(at: .init(index: 2, offset: 3), autoplay: true))
        value.pause()
        XCTAssertNotNil(value.install(request.ticket, at: request.position, duration: 10))
        XCTAssertFalse(value.wantsPlayback)
        XCTAssertEqual(value.phase, .ready)
        XCTAssertEqual(value.position, .init(index: 2, offset: 3))
    }

    func testCancelledRequestCannotInstallOrReportFailureOverNewRequest() throws {
        var value = coordinator()
        let old = try XCTUnwrap(value.prepare(at: .init(index: 0, offset: 0), autoplay: true))
        let latest = try XCTUnwrap(value.prepare(at: .init(index: 3, offset: 0), autoplay: true))
        XCTAssertFalse(value.accepts(old.ticket))
        XCTAssertNil(value.install(old.ticket, at: old.position, duration: 4))
        value.fail(old.ticket)
        XCTAssertEqual(value.phase, .preparing)
        XCTAssertTrue(value.wantsPlayback)
        XCTAssertNotNil(value.install(latest.ticket, at: latest.position, duration: 8))
        XCTAssertEqual(value.position.index, 3)
    }

    func testRapidSeeksAccumulateFromOriginalAnchorAndRejectOldDurationResult() throws {
        var value = coordinator()
        let first = try XCTUnwrap(value.seek(by: 15, from: .init(index: 1, offset: 2)))
        let second = try XCTUnwrap(value.seek(by: 15, from: .init(index: 6, offset: 0)))
        let third = try XCTUnwrap(value.seek(by: -15, from: .init(index: 7, offset: 0)))
        XCTAssertEqual(first.anchor, .init(index: 1, offset: 2))
        XCTAssertEqual(second.anchor, first.anchor)
        XCTAssertEqual(second.delta, 30)
        XCTAssertEqual(third.anchor, first.anchor)
        XCTAssertEqual(third.delta, 15)
        XCTAssertNil(value.install(second.ticket, at: .init(index: 6, offset: 0), duration: 8))
        XCTAssertNotNil(value.install(third.ticket, at: .init(index: 4, offset: 1), duration: 8))
        XCTAssertNil(value.pendingSeek)
        let subsequent = try XCTUnwrap(value.seek(by: 15, from: .init(index: 4, offset: 2)))
        XCTAssertEqual(subsequent.anchor, .init(index: 4, offset: 2))
        XCTAssertEqual(subsequent.delta, 15)
    }

    func testPauseWhileSeekingSurvivesRealDurationResolution() throws {
        var value = coordinator()
        value.setPlaybackIntent(true)
        let seek = try XCTUnwrap(value.seek(by: 15, from: .init(index: 0, offset: 1)))
        value.pause()
        XCTAssertNotNil(value.install(seek.ticket, at: .init(index: 3, offset: 2), duration: 9))
        XCTAssertFalse(value.wantsPlayback)
    }

    func testSystemSentenceCommandsPreservePauseAndNeverWrap() throws {
        var value = coordinator()
        let next = try XCTUnwrap(value.moveSentence(by: 1, from: 2))
        XCTAssertEqual(next.position, .init(index: 3, offset: 0))
        XCTAssertFalse(value.wantsPlayback)
        XCTAssertNotNil(value.install(next.ticket, at: next.position, duration: 4))
        let previous = try XCTUnwrap(value.moveSentence(by: -1, from: 3))
        XCTAssertEqual(previous.position.index, 2)
        XCTAssertFalse(value.wantsPlayback)
        XCTAssertNil(value.moveSentence(by: -1, from: 0))
        XCTAssertNil(value.moveSentence(by: 1, from: 7))
    }

    func testAppChapterPreparationIntentionallyStartsPlaying() throws {
        var value = coordinator()
        value.pause()
        let chapter = try XCTUnwrap(value.prepare(at: .init(index: 4, offset: 0), autoplay: true))
        XCTAssertTrue(value.wantsPlayback)
        XCTAssertEqual(chapter.position.offset, 0)
        XCTAssertNotNil(value.install(chapter.ticket, at: chapter.position, duration: 3))
        XCTAssertTrue(value.wantsPlayback)
    }

    func testConsecutiveVoiceChangesKeepOriginalFractionAndLatestPause() throws {
        var value = coordinator()
        value.setPlaybackIntent(true)
        let first = try XCTUnwrap(value.changeVoice(from: .init(index: 2, offset: 6), duration: 10))
        value.pause()
        let second = try XCTUnwrap(value.changeVoice(from: .init(index: 2, offset: 6), duration: 0))
        XCTAssertEqual(first.fraction, 0.6)
        XCTAssertEqual(second.fraction, 0.6)
        XCTAssertNil(value.install(first.ticket, at: first.position, duration: 20, fraction: first.fraction))
        XCTAssertNotNil(value.install(second.ticket, at: second.position, duration: 20, fraction: second.fraction))
        XCTAssertEqual(value.position.offset, 12, accuracy: 0.001)
        XCTAssertFalse(value.wantsPlayback)
    }

    func testInterruptionDuringPreparationCannotAutoplayUntilSystemAllows() throws {
        var value = coordinator()
        let pending = try XCTUnwrap(value.prepare(at: .init(index: 2, offset: 0), autoplay: true))
        value.interrupt()
        XCTAssertNotNil(value.install(pending.ticket, at: pending.position, duration: 5))
        XCTAssertFalse(value.wantsPlayback)
        XCTAssertTrue(value.endInterruption(shouldResume: true))
        XCTAssertTrue(value.wantsPlayback)
    }

    func testUserPauseOrSystemDenialPreventsInterruptionResume() {
        var value = coordinator()
        value.setPlaybackIntent(true); value.interrupt(); value.pause()
        XCTAssertFalse(value.endInterruption(shouldResume: true))
        XCTAssertFalse(value.wantsPlayback)
        value.setPlaybackIntent(true); value.interrupt()
        XCTAssertFalse(value.endInterruption(shouldResume: false))
        XCTAssertFalse(value.wantsPlayback)
    }

    func testManualLocationChangeDuringInterruptionDoesNotUnexpectedlyResume() throws {
        var value = coordinator()
        value.setPlaybackIntent(true); value.interrupt()
        _ = try XCTUnwrap(value.moveSentence(by: 1, from: 2))
        XCTAssertFalse(value.endInterruption(shouldResume: true))
        XCTAssertFalse(value.wantsPlayback)
    }

    func testStopKeepsCapturedSaveIdentityAndRejectsAllOldCallbacks() throws {
        var value = coordinator()
        let request = try XCTUnwrap(value.prepare(at: .init(index: 2, offset: 3), autoplay: true))
        let save = try XCTUnwrap(value.checkpoint(at: .init(index: 2, offset: 4.5)))
        value.stop()
        XCTAssertEqual(save.session.bookID, "first")
        XCTAssertEqual(save.session.addedAt, importedAt)
        XCTAssertEqual(save.position.offset, 4.5)
        XCTAssertNil(value.checkpoint(at: .init(index: 0, offset: 0)))
        XCTAssertNil(value.install(request.ticket, at: request.position, duration: 8))
        XCTAssertEqual(value.complete(request.ticket, successfully: true), .ignored)
        XCTAssertEqual(value.phase, .idle)
    }

    func testSwitchingBooksOrReimportingSameIDRejectsOldBatchAndSavesOriginalOwner() throws {
        var value = coordinator()
        let old = try XCTUnwrap(value.prepare(at: .init(index: 1, offset: 2), autoplay: true))
        let checkpoint = try XCTUnwrap(value.checkpoint(at: old.position))
        value.open(bookID: "second", addedAt: importedAt, sentenceCount: 2)
        _ = value.prepare(at: .init(index: 0, offset: 0), autoplay: true)
        XCTAssertNil(value.install(old.ticket, at: old.position, duration: 7))
        XCTAssertEqual(checkpoint.session.bookID, "first")
        value.open(bookID: "first", addedAt: importedAt.addingTimeInterval(1), sentenceCount: 8)
        _ = value.prepare(at: .init(index: 0, offset: 0), autoplay: true)
        XCTAssertFalse(value.accepts(old.ticket))
        XCTAssertNotEqual(value.session?.addedAt, checkpoint.session.addedAt)
    }

    func testNaturalFinishAdvancesOnlyCurrentPlayingGeneration() throws {
        var value = coordinator()
        let request = try XCTUnwrap(value.prepare(at: .init(index: 2, offset: 0), autoplay: true))
        XCTAssertEqual(value.complete(request.ticket, successfully: true), .ignored) // 尚未安装的回调不能前进。
        XCTAssertNotNil(value.install(request.ticket, at: request.position, duration: 4))
        XCTAssertEqual(value.complete(request.ticket, successfully: true), .advance(3))
        let newer = try XCTUnwrap(value.prepare(at: .init(index: 3, offset: 0), autoplay: nil))
        XCTAssertEqual(value.complete(request.ticket, successfully: true), .ignored)
        XCTAssertNotNil(value.install(newer.ticket, at: newer.position, duration: 4))
        value.pause()
        XCTAssertEqual(value.complete(newer.ticket, successfully: true), .finished)
        XCTAssertFalse(value.wantsPlayback)
        XCTAssertEqual(value.position.offset, 4)
        XCTAssertEqual(value.complete(newer.ticket, successfully: true), .ignored)
    }

    func testFailedDecodeCannotAdvanceAndInvalidAudioCannotInstall() throws {
        var value = coordinator()
        let request = try XCTUnwrap(value.prepare(at: .init(index: 7, offset: .nan), autoplay: true))
        XCTAssertEqual(request.position.offset, 0)
        XCTAssertNil(value.install(request.ticket, at: request.position, duration: .infinity))
        XCTAssertNotNil(value.install(request.ticket, at: request.position, duration: 4))
        XCTAssertNil(value.install(request.ticket, at: request.position, duration: 10)) // 重复完成不能重装。
        XCTAssertEqual(value.complete(request.ticket, successfully: false), .finished)
        XCTAssertEqual(value.phase, .failed)
        XCTAssertFalse(value.wantsPlayback)
    }

    func testMediaServiceReprepareKeepsIntentButCancelsPreviousTicket() throws {
        var value = coordinator()
        let old = try XCTUnwrap(value.prepare(at: .init(index: 4, offset: 1), autoplay: true))
        XCTAssertNotNil(value.install(old.ticket, at: old.position, duration: 9))
        let reset = try XCTUnwrap(value.prepare(at: .init(index: 4, offset: 2.5), autoplay: value.wantsPlayback))
        XCTAssertFalse(value.accepts(old.ticket))
        XCTAssertTrue(value.wantsPlayback)
        XCTAssertEqual(reset.position.offset, 2.5)
    }
    func testNaturalHandoffPreservesPreparedAudioAndRejectsOldPlayer() throws {
        var value = coordinator()
        let first = try XCTUnwrap(value.prepare(at: .init(index: 2, offset: 0), autoplay: true))
        XCTAssertEqual(first.transition, .explicit)
        XCTAssertNotNil(value.install(first.ticket, at: first.position, duration: 4))
        XCTAssertEqual(value.complete(first.ticket, successfully: true), .advance(3))
        let next = try XCTUnwrap(value.continueAfterCompletion(to: 3))
        XCTAssertEqual(next.transition, .continuous)
        XCTAssertTrue(value.wantsPlayback)
        XCTAssertFalse(value.accepts(first.ticket))
        XCTAssertEqual(value.complete(first.ticket, successfully: true), .ignored)
        value.pause()
        XCTAssertNotNil(value.install(next.ticket, at: next.position, duration: 5))
        XCTAssertFalse(value.wantsPlayback)
    }

    func testNaturalHandoffCannotSkipPauseOrExplicitNavigation() throws {
        var value = coordinator()
        XCTAssertNil(value.continueAfterCompletion(to: 1))
        let first = try XCTUnwrap(value.prepare(at: .init(index: 2, offset: 0), autoplay: true))
        XCTAssertNotNil(value.install(first.ticket, at: first.position, duration: 4))
        XCTAssertNil(value.continueAfterCompletion(to: 4))
        value.pause()
        XCTAssertNil(value.continueAfterCompletion(to: 3))
        let changed = try XCTUnwrap(value.changeVoice(from: .init(index: 2, offset: 1), duration: 4))
        XCTAssertEqual(changed.transition, .explicit)
        XCTAssertNil(value.continueAfterCompletion(to: 3))
        value.stop()
        XCTAssertNil(value.continueAfterCompletion(to: 3))
    }

    func testFailureRetryRebuildsPreparationAndCanContinueToNextSentence() throws {
        var value = coordinator()
        let first = try XCTUnwrap(value.prepare(at: .init(index: 2, offset: 0), autoplay: true))
        XCTAssertNotNil(value.install(first.ticket, at: first.position, duration: 10))
        XCTAssertTrue(value.canResumeInstalledPlayer)
        value.fail()
        value.setPlaybackIntent(true)
        XCTAssertFalse(value.canResumeInstalledPlayer, "仅恢复播放意图不能让 failed 播放器重新接收完成事件")
        let recovery = try XCTUnwrap(value.recoveryPosition(at: .init(index: 2, offset: 4.5), duration: 10))
        XCTAssertEqual(recovery.offset, 4.5)
        let retry = try XCTUnwrap(value.prepare(at: recovery, autoplay: true))
        XCTAssertNotEqual(first.ticket, retry.ticket)
        XCTAssertNotNil(value.install(retry.ticket, at: retry.position, duration: 10))
        XCTAssertTrue(value.canResumeInstalledPlayer)
        XCTAssertEqual(value.complete(first.ticket, successfully: true), .ignored)
        XCTAssertEqual(value.complete(retry.ticket, successfully: true), .advance(3))
        XCTAssertNotNil(value.continueAfterCompletion(to: 3))
    }

    func testFailureAtSentenceEndRetriesFromStartAndUnknownDurationPreservesOffset() throws {
        var value = coordinator()
        let request = try XCTUnwrap(value.prepare(at: .init(index: 2, offset: 0), autoplay: true))
        XCTAssertNil(value.recoveryPosition(at: request.position, duration: 10))
        XCTAssertNotNil(value.install(request.ticket, at: request.position, duration: 10))
        value.fail()
        XCTAssertEqual(value.recoveryPosition(at: .init(index: 2, offset: 10), duration: 10)?.offset, 0)
        XCTAssertEqual(value.recoveryPosition(at: .init(index: 2, offset: 12), duration: 10)?.offset, 0)
        XCTAssertEqual(value.recoveryPosition(at: .init(index: 2, offset: .nan), duration: 10)?.offset, 0)
        XCTAssertEqual(value.recoveryPosition(at: .init(index: 2, offset: 4), duration: 0)?.offset, 4)
        XCTAssertEqual(value.recoveryPosition(at: .init(index: 2, offset: 4), duration: .nan)?.offset, 4)
    }

}
