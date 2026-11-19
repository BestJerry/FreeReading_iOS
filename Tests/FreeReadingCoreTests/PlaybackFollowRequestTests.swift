import XCTest
@testable import FreeReadingCore

final class PlaybackFollowRequestTests: XCTestCase {
    private let importedAt = Date(timeIntervalSince1970: 100)

    func testExplicitRestartOverridesManualOffButSamePlaybackCannotOverrideItAgain() {
        var enabled = false
        var previous: PlaybackFollowRequest?
        let start = PlaybackFollowRequest(bookID: "book", addedAt: importedAt)
        if let preference = start.followingPreference(bookID: "book", addedAt: importedAt, after: previous, currentPreference: true) {
            enabled = preference; previous = start
        }
        XCTAssertTrue(enabled, "开始朗读必须覆盖此前手动关闭")
        enabled = false
        if let preference = start.followingPreference(bookID: "book", addedAt: importedAt, after: previous, currentPreference: enabled) { enabled = preference }
        XCTAssertFalse(enabled, "自然换句和重复快照沿用同一个事件，不得覆盖本次关闭")
        let resumed = PlaybackFollowRequest(bookID: "book", addedAt: importedAt)
        if let preference = resumed.followingPreference(bookID: "book", addedAt: importedAt, after: previous, currentPreference: true) { enabled = preference }
        XCTAssertTrue(enabled, "下一次明确恢复朗读必须重新开启")
    }

    func testAnotherBookAndRemovedImportBatchCannotPullTheReaderAway() {
        let other = PlaybackFollowRequest(bookID: "other", addedAt: importedAt)
        XCTAssertNil(other.followingPreference(bookID: "book", addedAt: importedAt, after: nil, currentPreference: true))
        let oldImport = PlaybackFollowRequest(bookID: "book", addedAt: importedAt)
        XCTAssertNil(oldImport.followingPreference(bookID: "book", addedAt: importedAt.addingTimeInterval(1), after: nil, currentPreference: true))
        let current = PlaybackFollowRequest(bookID: "book", addedAt: importedAt.addingTimeInterval(1))
        XCTAssertEqual(current.followingPreference(bookID: "book", addedAt: current.addedAt, after: other, currentPreference: true), true)
    }

    func testDelayedStartEventDoesNotOverrideANewerManualDisable() {
        let started = PlaybackFollowRequest(bookID: "book", addedAt: importedAt)
        XCTAssertEqual(started.followingPreference(bookID: "book", addedAt: importedAt, after: nil, currentPreference: false), false)
        XCTAssertNil(started.followingPreference(bookID: "book", addedAt: importedAt, after: started, currentPreference: false))
        let resumed = PlaybackFollowRequest(bookID: "book", addedAt: importedAt)
        XCTAssertEqual(resumed.followingPreference(bookID: "book", addedAt: importedAt, after: started, currentPreference: true), true)
    }

    func testManualNavigationAcknowledgesTheAlreadyPublishedStartUntilTheNextResume() {
        let started = PlaybackFollowRequest(bookID: "book", addedAt: importedAt)
        // 页面手动浏览会登记当前起播事件；即使偏好仍开着，迟到事件也不能解除脱离状态。
        let acknowledged = started
        XCTAssertNil(started.followingPreference(bookID: "book", addedAt: importedAt, after: acknowledged, currentPreference: true))
        let resumed = PlaybackFollowRequest(bookID: "book", addedAt: importedAt)
        XCTAssertEqual(resumed.followingPreference(bookID: "book", addedAt: importedAt, after: acknowledged, currentPreference: true), true)
    }

    func testPauseAfterManualBrowsingDoesNotBecomeANewReadingStart() {
        XCTAssertTrue(ReaderProgressPolicy.shouldToggleExistingAudio(ownsAudio: true, wantsPlayback: true, isPreparing: false, fromReading: true))
        XCTAssertTrue(ReaderProgressPolicy.shouldToggleExistingAudio(ownsAudio: true, wantsPlayback: false, isPreparing: true, fromReading: true))
        XCTAssertFalse(ReaderProgressPolicy.shouldToggleExistingAudio(ownsAudio: true, wantsPlayback: false, isPreparing: false, fromReading: true))
        XCTAssertTrue(ReaderProgressPolicy.shouldToggleExistingAudio(ownsAudio: true, wantsPlayback: false, isPreparing: false, fromReading: false))
        XCTAssertFalse(ReaderProgressPolicy.shouldToggleExistingAudio(ownsAudio: false, wantsPlayback: true, isPreparing: true, fromReading: false))
    }
}
