import XCTest
@testable import FreeReadingCore

final class ReaderProgressPolicyTests: XCTestCase {
    func testWholeBookProgressWeightsBodyRatherThanGivingCoverAnEqualChapter() {
        XCTAssertEqual(ReaderProgressPolicy.totalProgress(chapterIndex: 1, pageProgress: 0.5,
            chapterWeights: [10, 990, 0], chapterCount: 3), 0.505, accuracy: 0.00001)
        XCTAssertEqual(ReaderProgressPolicy.totalProgress(chapterIndex: 2, pageProgress: 0,
            chapterWeights: [10, 990, 0], chapterCount: 3), 1)
    }

    func testInvalidAndVeryLargeWeightsRemainFinite() {
        XCTAssertEqual(ReaderProgressPolicy.totalProgress(chapterIndex: 1, pageProgress: 0.5,
            chapterWeights: [Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude], chapterCount: 2), 0.75)
        XCTAssertEqual(ReaderProgressPolicy.totalProgress(chapterIndex: 1, pageProgress: .nan,
            chapterWeights: [.infinity, -1], chapterCount: 2), 0.5)
        XCTAssertEqual(ReaderProgressPolicy.totalProgress(chapterIndex: 1, pageProgress: 9,
            chapterWeights: [], chapterCount: 2), 1)
        XCTAssertEqual(ReaderProgressPolicy.totalProgress(chapterIndex: 99, pageProgress: 0,
            chapterWeights: [10], chapterCount: 1), 1)
        XCTAssertEqual(ReaderProgressPolicy.totalProgress(chapterIndex: -1, pageProgress: 1,
            chapterWeights: [10], chapterCount: 1), 0)
    }

    func testStoppedListeningCursorSurvivesVisualCallbacksUntilManualReading() {
        XCTAssertFalse(ReaderProgressPolicy.canSaveVisual(restorationComplete: true, hasCurrentAudio: false, hasResumeProgress: true, fromReading: false),
            "stop 后的 scroll、离页或后台回调不能把句内秒数覆盖成零。")
        XCTAssertTrue(ReaderProgressPolicy.canSaveVisual(restorationComplete: true, hasCurrentAudio: false, hasResumeProgress: true, fromReading: true))
        XCTAssertFalse(ReaderProgressPolicy.canSaveVisual(restorationComplete: true, hasCurrentAudio: true, hasResumeProgress: false, fromReading: true))
        XCTAssertFalse(ReaderProgressPolicy.canSaveVisual(restorationComplete: false, hasCurrentAudio: false, hasResumeProgress: false, fromReading: true))
    }

    func testMetadataRestoreUsesStableSectionIDWithoutSpeechIndex() {
        XCTAssertEqual(ReaderProgressPolicy.sectionID(elementID: "fr-section-4280"), 4280)
        XCTAssertNil(ReaderProgressPolicy.sectionID(elementID: "publisher-title"))
        XCTAssertNil(ReaderProgressPolicy.sectionID(elementID: "fr-section--1"))
        XCTAssertNil(ReaderProgressPolicy.sectionID(elementID: nil))
    }

    func testUnreadyChapterNavigationSavesIntendedChapterRatherThanPreviousDOM() throws {
        let book = fixture()
        let next = try XCTUnwrap(ReaderProgressPolicy.pendingNavigationProgress(book: book, chapterIndex: 1, target: .progress(0)))
        XCTAssertEqual(next.chapterIndex, 1)
        XCTAssertEqual(next.pageProgress, 0)
        XCTAssertEqual(ReaderProgressPolicy.restorationTarget(progress: next), .progress(0))
        let previousEnd = try XCTUnwrap(ReaderProgressPolicy.pendingNavigationProgress(book: book, chapterIndex: 0, target: .progress(1)))
        XCTAssertEqual(previousEnd.chapterIndex, 0)
        XCTAssertEqual(ReaderProgressPolicy.restorationTarget(progress: previousEnd), .progress(1))
    }

    func testUnreadyContentsFragmentSurvivesSaveAndMetadataOnlyRestore() throws {
        let book = fixture()
        let target = ReaderLocationTarget.fragment("第二节 😀")
        let saved = try XCTUnwrap(ReaderProgressPolicy.pendingNavigationProgress(book: book, chapterIndex: 1, target: target))
        XCTAssertEqual(ReaderProgressPolicy.restorationTarget(progress: saved), target)
        XCTAssertFalse(ReaderProgressPolicy.canResumeAudio(progress: saved, book: book),
            "还没有 DOM 句子映射的目录锚点应从可见原文起播，不能借用该章首句。")
        let section = try XCTUnwrap(ReaderProgressPolicy.pendingNavigationProgress(book: book, chapterIndex: 1, target: .section(1, 999)))
        XCTAssertEqual(section.textOffset, book.sections[1].text.utf16.count)
        XCTAssertEqual(ReaderProgressPolicy.restorationTarget(progress: section), .section(1, book.sections[1].text.utf16.count))
        XCTAssertTrue(ReaderProgressPolicy.canResumeAudio(progress: section, book: book))
    }

    func testUtf16CursorMapsToSentenceAndParagraphStartWithoutChangingSourceText() throws {
        let book = fixture()
        let boundary = ("第一句。" as NSString).length
        XCTAssertEqual(ReaderProgressPolicy.sentenceIndex(book: book, chapterIndex: 1, sectionID: 1, textOffset: boundary, startOfParagraph: false), 2)
        XCTAssertEqual(ReaderProgressPolicy.sentenceIndex(book: book, chapterIndex: 1, sectionID: 1, textOffset: boundary + 2, startOfParagraph: true), 1)
        let saved = try XCTUnwrap(ReaderProgressPolicy.readingProgress(book: book, chapterIndex: 1, sectionID: 1,
            textOffset: boundary + 2, pageProgress: 0.6))
        XCTAssertEqual(saved.sentenceIndex, 2)
        XCTAssertEqual(saved.textOffset, boundary + 2)
        XCTAssertEqual(saved.elementID, "fr-section-1")
        XCTAssertEqual(saved.audioOffset, 0)
        XCTAssertEqual(saved.pageProgress, 0.6)
    }

    func testImageOnlyPageAndMalformedStaleSection() throws {
        let book = fixture()
        let image = try XCTUnwrap(ReaderProgressPolicy.readingProgress(book: book, chapterIndex: 2, sectionID: nil, textOffset: 30, pageProgress: 0.75))
        XCTAssertNil(image.elementID)
        XCTAssertEqual(image.textOffset, 0)
        XCTAssertEqual(image.chapterIndex, 2)
        XCTAssertEqual(image.pageProgress, 0.75)
        XCTAssertNil(ReaderProgressPolicy.readingProgress(book: book, chapterIndex: 1, sectionID: 0, textOffset: 0, pageProgress: 0.2),
            "旧页面的段落不能保存为新章节的游标。")
        XCTAssertNil(ReaderProgressPolicy.readingProgress(book: book, chapterIndex: 50, sectionID: nil, textOffset: 0, pageProgress: 0))
    }

    func testPlaybackButtonPausesActiveAudioAndRestartsAtTheNewLocationAfterBrowsingWhilePaused() {
        XCTAssertTrue(ReaderProgressPolicy.shouldToggleExistingAudio(ownsAudio: true, wantsPlayback: true, fromReading: true))
        XCTAssertFalse(ReaderProgressPolicy.shouldToggleExistingAudio(ownsAudio: true, wantsPlayback: false, fromReading: true))
        XCTAssertTrue(ReaderProgressPolicy.shouldToggleExistingAudio(ownsAudio: true, wantsPlayback: false, fromReading: false))
        XCTAssertFalse(ReaderProgressPolicy.shouldToggleExistingAudio(ownsAudio: false, wantsPlayback: true, fromReading: false))
    }

    func testManualPageStaysUntilTheNextSentenceActuallyPlays() {
        let duringSpeech = ReaderAudioNavigationDeferral.readingSentence(6)
        XCTAssertTrue(duringSpeech.shouldWait(wantsPlayback: true, isPlaying: true, sentenceIndex: 6))
        XCTAssertTrue(duringSpeech.shouldWait(wantsPlayback: true, isPlaying: false, sentenceIndex: 7))
        XCTAssertFalse(duringSpeech.shouldWait(wantsPlayback: true, isPlaying: true, sentenceIndex: 7))
        XCTAssertFalse(duringSpeech.shouldWait(wantsPlayback: false, isPlaying: false, sentenceIndex: 6))

        let duringPreparation = ReaderAudioNavigationDeferral.waitingForPlayback
        XCTAssertTrue(duringPreparation.shouldWait(wantsPlayback: true, isPlaying: false, sentenceIndex: 7))
        XCTAssertFalse(duringPreparation.shouldWait(wantsPlayback: true, isPlaying: true, sentenceIndex: 7))
    }

    private func fixture() -> SpeechBook {
        let first = "第一句。", second = "第二😀句。"
        let start = first.utf16.count, end = (first + second).utf16.count
        return SpeechBook(record: BookRecord(id: "reader-test", title: "阅读规则"),
            chapters: [BookChapter(id: 0, href: "cover.xhtml", title: "扉页"), BookChapter(id: 1, href: "body.xhtml", title: "正文"), BookChapter(id: 2, href: "image.xhtml", title: "插图")],
            sections: [BookSection(id: 0, chapterIndex: 0, elementID: "fr-section-0", text: "扉页"), BookSection(id: 1, chapterIndex: 1, elementID: "fr-section-1", text: first + second)],
            sentences: [SpeechSentence(id: 0, sectionID: 0, range: TextRange(start: 0, end: 2), chapterIndex: 0), SpeechSentence(id: 1, sectionID: 1, range: TextRange(start: 0, end: start), chapterIndex: 1), SpeechSentence(id: 2, sectionID: 1, range: TextRange(start: start, end: end), chapterIndex: 1)], contents: [])
    }
}
