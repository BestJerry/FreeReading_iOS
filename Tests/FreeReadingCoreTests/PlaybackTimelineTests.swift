import XCTest
@testable import FreeReadingCore

final class PlaybackTimelineTests: XCTestCase {
    private func fixture() -> SpeechBook {
        let texts = ["一。", "二二。", "三。", "四四四。", "五。"]
        let chapters = [0, 0, 2, 2, 4]
        let sections = texts.enumerated().map { BookSection(id: $0.offset, chapterIndex: chapters[$0.offset], elementID: "s\($0.offset)", text: $0.element) }
        let sentences = texts.enumerated().map { SpeechSentence(id: $0.offset, sectionID: $0.offset, range: TextRange(start: 0, end: $0.element.utf16.count), chapterIndex: chapters[$0.offset]) }
        return SpeechBook(record: BookRecord(id: "fixture", title: "测试"), chapters: [], sections: sections, sentences: sentences, contents: [])
    }

    func testAdjacentChapterButtonsAlwaysTargetAnotherChapterStart() {
        let timeline = PlaybackTimeline(book: fixture())
        XCTAssertNil(timeline.previousChapter(at: 1))
        XCTAssertEqual(timeline.nextChapter(at: 1), 2)
        XCTAssertEqual(timeline.previousChapter(at: 3), 0)
        XCTAssertEqual(timeline.nextChapter(at: 3), 4)
        XCTAssertEqual(timeline.previousChapter(at: 4), 2)
        XCTAssertNil(timeline.nextChapter(at: 4))
    }

    func testChapterFractionHasEqualAdjacentBoundariesAndDoesNotResetPerSentence() {
        let timeline = PlaybackTimeline(book: fixture())
        XCTAssertEqual(timeline.fraction(at: 0, offset: 10, duration: 10), 0.4, accuracy: 0.000_01)
        XCTAssertEqual(timeline.fraction(at: 1, offset: 0, duration: 10), 0.4, accuracy: 0.000_01)
        XCTAssertEqual(timeline.fraction(at: 1, offset: 10, duration: 10), 1)
        XCTAssertEqual(timeline.fraction(at: 2, offset: 0, duration: 10), 0)
        XCTAssertEqual(timeline.fraction(at: 2, offset: .infinity, duration: 0), 0)
    }

    func testForwardSeekUsesActualDurationsAcrossSeveralSentences() async throws {
        let lengths = [3.0, 4, 8, 10]
        let target = try await PlaybackTimeline.seek(sentenceCount: lengths.count, from: .init(index: 0, offset: 2), by: 15) { lengths[$0] }
        XCTAssertEqual(target, SentencePosition(index: 3, offset: 2))
    }

    func testBackwardSeekAndBookEdgesClampToRealBounds() async throws {
        let lengths = [3.0, 4, 8, 10]
        let backwards = try await PlaybackTimeline.seek(sentenceCount: lengths.count, from: .init(index: 3, offset: 2), by: -15) { lengths[$0] }
        XCTAssertEqual(backwards, SentencePosition(index: 0, offset: 2))
        let beginning = try await PlaybackTimeline.seek(sentenceCount: lengths.count, from: .init(index: 0, offset: 1), by: -15) { lengths[$0] }
        XCTAssertEqual(beginning, SentencePosition(index: 0, offset: 0))
        let ending = try await PlaybackTimeline.seek(sentenceCount: lengths.count, from: .init(index: 3, offset: 9), by: 15) { lengths[$0] }
        XCTAssertEqual(ending, SentencePosition(index: 3, offset: 10))
    }

    func testExactForwardBoundaryTargetsTheFollowingSentence() async throws {
        let target = try await PlaybackTimeline.seek(sentenceCount: 2, from: .init(index: 0, offset: 2), by: 1) { _ in 3 }
        XCTAssertEqual(target, SentencePosition(index: 1, offset: 0))
    }

    func testInvalidDurationCannotInventAnAudioPosition() async {
        do {
            _ = try await PlaybackTimeline.seek(sentenceCount: 1, from: .init(index: 0, offset: 0), by: 15) { _ in .nan }
            XCTFail("无效时长应拒绝跳转")
        } catch { XCTAssertTrue(error is PlaybackTimeline.TimelineError) }
    }
}
