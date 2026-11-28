import CoreGraphics
import CoreText
import Foundation
import PDFKit
import XCTest
@testable import FreeReadingCore

final class PDFRepositoryTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writePDF(to url: URL, pages: [String?], title: String? = nil, password: String? = nil) throws {
        var options: [CFString: Any] = [:]
        if let title { options[kCGPDFContextTitle] = title }
        if let password {
            options[kCGPDFContextUserPassword] = password
            options[kCGPDFContextOwnerPassword] = "pdf-owner"
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &mediaBox, options as CFDictionary))
        for text in pages {
            context.beginPDFPage(nil)
            if let text {
                let key = NSAttributedString.Key(kCTFontAttributeName as String)
                let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [key: font]))
                context.textPosition = CGPoint(x: 16, y: 360)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    func testPDFImportKeepsOriginalPagesAndIndexesTextOnTheCorrectPage() async throws {
        let root = try temporary()
        let source = root.appendingPathComponent("file.PDF")
        let first = "The first page can be read aloud."
        let third = "The third page contains another line."
        try writePDF(to: source, pages: [first, nil, third], title: "PDF 章节")
        let expectedBytes = try Data(contentsOf: source)
        let repository = try BookRepository(root: root.appendingPathComponent("library"))
        let imported = try await repository.importDocument(from: source)
        XCTAssertEqual(imported.record.format, .pdf)
        XCTAssertEqual(imported.record.title, "PDF 章节")
        XCTAssertEqual(imported.record.chapterCount, 3)
        XCTAssertEqual(imported.contents.map(\.chapterIndex), [0, 1, 2])
        XCTAssertEqual(imported.sentences.map(\.chapterIndex), [0, 2])
        XCTAssertEqual(imported.text(at: 0), first)
        XCTAssertEqual(imported.text(at: 1), third)
        let localPDF = try repository.pdfURL(bookID: imported.record.id)
        XCTAssertEqual(localPDF.lastPathComponent, "book.pdf")
        XCTAssertEqual(try Data(contentsOf: localPDF), expectedBytes)
        let duplicate = try await repository.importDocument(from: source)
        XCTAssertEqual(duplicate.record, imported.record)
        try FileManager.default.removeItem(at: source)

        let reopened = try BookRepository(root: repository.root)
        let bootstrap = try await reopened.prepareReadingBook(id: imported.record.id)
        XCTAssertEqual(bootstrap.book.chapters.count, 3)
        let loaded = try await reopened.loadSpeechBook(id: imported.record.id)
        XCTAssertEqual(loaded, imported)
    }

    func testImageOnlyPDFCanSaveVisualProgressWithoutAnySentences() async throws {
        let root = try temporary()
        let source = root.appendingPathComponent("无文字.pdf")
        try writePDF(to: source, pages: [nil, nil])
        let repository = try BookRepository(root: root.appendingPathComponent("library"))
        let book = try await repository.importDocument(from: source)
        XCTAssertEqual(book.record.title, "无文字")
        XCTAssertEqual(book.record.chapterCount, 2)
        XCTAssertTrue(book.sentences.isEmpty)
        try await repository.savePDFReadingPage(bookID: book.record.id, index: 1, expectedAddedAt: book.record.addedAt)

        let reopened = try BookRepository(root: repository.root)
        let stored = try await reopened.prepareReadingBook(id: book.record.id)
        XCTAssertEqual(stored.pdfPage, 1)
        let speech = try await reopened.loadSpeechBook(id: book.record.id)
        XCTAssertTrue(speech.sentences.isEmpty)
    }

    func testChangingPDFReadingPagePreservesTheAudioCursor() async throws {
        let root = try temporary()
        let source = root.appendingPathComponent("pages.pdf")
        try writePDF(to: source, pages: ["First page.", "Second page."])
        let repository = try BookRepository(root: root.appendingPathComponent("library"))
        let book = try await repository.importDocument(from: source)
        let progress = ReadingProgress(bookID: book.record.id, chapterIndex: 0,
            elementID: "pdf-page-0", sentenceIndex: 0, audioOffset: 1.5)
        try await repository.saveProgress(progress, expectedAddedAt: book.record.addedAt)
        let earlier = Date()
        try await repository.savePDFReadingPage(bookID: book.record.id, index: 1,
            expectedAddedAt: book.record.addedAt, updatedAt: earlier.addingTimeInterval(1))
        try await repository.savePDFReadingPage(bookID: book.record.id, index: 0,
            expectedAddedAt: book.record.addedAt, updatedAt: earlier)
        let restored = try await BookRepository(root: repository.root).prepareReadingBook(id: book.record.id)
        XCTAssertEqual(restored.pdfPage, 1)
        XCTAssertEqual(restored.progress, progress)
    }

    func testPDFTextIndexUsesTheSameByteLimitForWritingAndColdLoading() throws {
        let root = try temporary()
        let first = BookSection(id: 0, chapterIndex: 0, elementID: "pdf-page-0", text: "First page.")
        var section = BookSection(id: 1, chapterIndex: 1, elementID: "pdf-page-1", text: "")
        let encoder = JSONEncoder()
        let emptyBytes = try encoder.encode(section).count
        section.text = String(repeating: "a", count: BookIndexIO.lineByteLimit - emptyBytes)
        let record = BookRecord(id: String(repeating: "a", count: 64), title: "长文本页",
                                chapterCount: 2, sentenceCount: 2, format: .pdf)
        let sections = [first, section]
        var index = SpeechBook(record: record,
                               chapters: sections.map { BookChapter(id: $0.chapterIndex, href: $0.elementID, title: "第 \($0.chapterIndex + 1) 页") },
                               sections: sections,
                               sentences: sections.map { SpeechSentence(id: $0.id, sectionID: $0.id, range: TextRange(start: 0, end: 1), chapterIndex: $0.chapterIndex) },
                               contents: [])

        try BookIndexIO.write(index, directory: root)
        XCTAssertEqual(try BookIndexIO.load(directory: root, metadata: record).book, index)

        index.sections[1].text.append("a")
        let expected = BookError.invalid("听书索引单项过大")
        XCTAssertThrowsError(try BookIndexIO.write(index, directory: root)) { XCTAssertEqual($0 as? BookError, expected) }

        // 第一行错开读取边界，使超长行的换行符和最后几个字节落在同一读取块内。
        var oversizedLines = try encoder.encode(first)
        oversizedLines.append(10)
        oversizedLines.append(try encoder.encode(index.sections[1]))
        oversizedLines.append(10)
        try oversizedLines.write(to: root.appendingPathComponent("sections.jsonl"))
        XCTAssertThrowsError(try BookIndexIO.load(directory: root, metadata: record)) { XCTAssertEqual($0 as? BookError, expected) }
    }

    func testDamagedAndPasswordProtectedPDFsAreNotAddedToLibrary() async throws {
        let root = try temporary()
        let invalid = root.appendingPathComponent("损坏.pdf")
        try Data("Not a PDF".utf8).write(to: invalid)
        let protected = root.appendingPathComponent("锁定.pdf")
        try writePDF(to: protected, pages: ["Locked."], password: "open-pdf")
        let repository = try BookRepository(root: root.appendingPathComponent("library"))
        for (file, message) in [(invalid, "PDF 文件损坏或格式无效"), (protected, "PDF 需要密码，请先解锁后再导入")] {
            do {
                _ = try await repository.importDocument(from: file)
                XCTFail("应拒绝 \(file.lastPathComponent)")
            } catch { XCTAssertEqual(error as? BookError, .invalid(message)) }
        }
        let records = try await repository.books()
        XCTAssertTrue(records.isEmpty)
    }
}
