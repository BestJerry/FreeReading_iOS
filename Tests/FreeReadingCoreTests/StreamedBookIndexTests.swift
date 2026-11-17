import XCTest
import Foundation
@testable import FreeReadingCore

/// 大索引使用程序生成的原创句子，验证存储结构和并发读取，无需私人电子书或真机。
final class StreamedBookIndexTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("StreamedBookIndex-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testHundredThousandSentencesUseOneSharedSectionAndBoundedStreamBuffer() async throws {
        let library = try BookRepository(root: directory)
        let count = 100_000
        let record = BookRecord(id: String(repeating: "a", count: 64), title: "原创长书", chapterCount: 1, sentenceCount: count)
        let book = SpeechBook(record: record, chapters: [BookChapter(id: 0, href: "chapter.xhtml", title: "正文")],
                              sections: [BookSection(id: 0, chapterIndex: 0, elementID: "fr-section-0", text: String(repeating: "字。", count: count))],
                              sentences: (0..<count).map { SpeechSentence(id: $0, sectionID: 0, range: TextRange(start: $0 * 2, end: $0 * 2 + 2), chapterIndex: 0) },
                              contents: [ContentsEntry(id: "chapter", title: "正文", chapterIndex: 0)])
        let folder = library.bookDirectory(id: record.id)
        try install(book, folder: folder)
        let direct = try BookIndexIO.load(directory: folder, metadata: record)
        XCTAssertFalse(direct.legacy)
        XCTAssertEqual(direct.book.sentences.count, count)
        XCTAssertEqual(direct.book.sections.count, 1)
        XCTAssertEqual(direct.book.text(at: count - 1), "字。")
        // 600 KB 的共享中文段落决定最大行缓冲；约 10 MB 的句子文件不会整份进入 Data。
        XCTAssertLessThan(direct.peakBufferedBytes, 1024 * 1024)
        XCTAssertLessThan(try Data(contentsOf: folder.appendingPathComponent("index.json")).count, 1024)
        let bootstrap = try await library.prepareReadingBook(id: record.id)
        XCTAssertNil(bootstrap.cachedSpeechBook)
        XCTAssertEqual(bootstrap.book.chapterWeights, [200_000])
        async let first = library.loadSpeechBook(id: record.id)
        async let second = library.loadSpeechBook(id: record.id)
        async let third = library.loadSpeechBook(id: record.id)
        let books = try await [first, second, third]
        let addresses = books.map { $0.sentences.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress!) } }
        XCTAssertEqual(Set(addresses).count, 1, "并发完整加载应复用同一个共享数组")

        let oldLoad = Task { try await BookRepository(root: directory).loadSpeechBook(id: record.id) }
        try await library.removeBook(id: record.id)
        var replacement = book; replacement.record.addedAt = record.addedAt.addingTimeInterval(1)
        try install(replacement, folder: folder)
        _ = await oldLoad.result
        let fresh = try await library.loadSpeechBook(id: record.id)
        XCTAssertEqual(fresh.record.addedAt, replacement.record.addedAt)
        try await library.removeBook(id: record.id)
        do { _ = try await library.prepareReadingBook(id: record.id); XCTFail("Removed book resurrected") } catch {}
    }

    func testWeightsUseChapterTextLengthAndEmptyChaptersHaveNoInventedLength() {
        let record = BookRecord(id: String(repeating: "b", count: 64), title: "权重", chapterCount: 3, sentenceCount: 4)
        let book = SpeechBook(record: record,
                              chapters: (0..<3).map { BookChapter(id: $0, href: "\($0).xhtml", title: "第\($0)章") },
                              sections: [BookSection(id: 0, chapterIndex: 0, elementID: "fr-section-0", text: "甲。"), BookSection(id: 1, chapterIndex: 1, elementID: "fr-section-1", text: "乙。丙。丁。")],
                              sentences: [], contents: [])
        XCTAssertEqual(ReadingBook(book: book).chapterWeights, [2, 6, 0])
    }

    func testIntegerImportPercentHandlesBoundariesAndInt64Overflow() {
        XCTAssertEqual(ImportProgress(stage: .copying, completed: 29, total: 100).percent, 29)
        XCTAssertEqual(ImportProgress(stage: .copying, completed: 2, total: 3).percent, 66)
        XCTAssertEqual(ImportProgress(stage: .copying, completed: Int64.max - 1, total: Int64.max).percent, 99)
        XCTAssertEqual(ImportProgress(stage: .copying, completed: Int64.max, total: Int64.max).percent, 100)
        XCTAssertEqual(ImportProgress(stage: .copying, completed: -1, total: 10).percent, 0)
        XCTAssertEqual(ImportProgress(stage: .copying, completed: 20, total: 10).percent, 100)
        XCTAssertNil(ImportProgress(stage: .copying, total: 0).percent)
        XCTAssertNil(ImportProgress(stage: .copying).percent)
    }

    private func install(_ book: SpeechBook, folder: URL) throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("content"), withIntermediateDirectories: true)
        try Data("<html><body><p data-fr-section=\"0\">原创测试。</p></body></html>".utf8).write(to: folder.appendingPathComponent("content/chapter.xhtml"))
        try BookIndexIO.write(book, directory: folder)
        try BookIndexIO.writeJSON(book.record, to: folder.appendingPathComponent("book.json"), limit: 128 * 1024)
    }
}
