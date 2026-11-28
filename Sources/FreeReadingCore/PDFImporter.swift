import Foundation
import NaturalLanguage
import PDFKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 保留 PDF 每页原始文字和偏移，便于朗读时定位到该页文本。
enum PDFImporter {
    static func pageIdentifier(_ index: Int) -> String { "pdf-page-\(index)" }

    static func open(source: URL, suggestedTitle: String, id: String,
                     progress: @Sendable (ImportProgress) -> Void) throws -> SpeechBook {
        progress(ImportProgress(stage: .validating))
        guard let document = PDFDocument(url: source) else { throw BookError.invalid("PDF 文件损坏或格式无效") }
        guard !document.isLocked else { throw BookError.invalid("PDF 需要密码，请先解锁后再导入") }
        let pageCount = document.pageCount
        guard pageCount > 0 else { throw BookError.invalid("PDF 没有可阅读的页面") }
        guard pageCount <= BookLimits.resources else { throw BookError.invalid("PDF 页数超过可支持容量") }

        let metadata = document.documentAttributes
        let title = metadataText(metadata?[PDFDocumentAttribute.titleAttribute])
            ?? metadataText(suggestedTitle) ?? "未命名 PDF"
        let author = metadataText(metadata?[PDFDocumentAttribute.authorAttribute]) ?? ""
        let canExtract = document.allowsCopying
        var chapters: [BookChapter] = []
        var sections: [BookSection] = []
        var sentences: [SpeechSentence] = []
        var contents: [ContentsEntry] = []
        var totalCharacters = 0
        var languageSample = ""
        var lastUpdate = ProcessInfo.processInfo.systemUptime
        chapters.reserveCapacity(pageCount)
        contents.reserveCapacity(pageCount)
        progress(ImportProgress(stage: .indexing, completed: 0, total: Int64(pageCount)))

        for index in 0..<pageCount {
            try Task.checkCancellation()
            let text = try autoreleasepool {
                guard let page = document.page(at: index) else { throw BookError.invalid("PDF 页面损坏，无法读取") }
                return canExtract ? page.string ?? "" : ""
            }
            let pageID = pageIdentifier(index)
            let pageTitle = "第 \(index + 1) 页"
            chapters.append(BookChapter(id: index, href: pageID, title: pageTitle))
            contents.append(ContentsEntry(id: pageID, title: pageTitle, chapterIndex: index))

            let characterCount = text.utf16.count
            guard characterCount <= BookLimits.textCharacters - totalCharacters else {
                throw BookError.invalid("PDF 正文超过可支持容量")
            }
            totalCharacters += characterCount
            let ranges = SentenceRanges.split(text)
            if !ranges.isEmpty {
                guard ranges.count <= BookLimits.sentences - sentences.count else {
                    throw BookError.invalid("PDF 句子数超过可支持容量")
                }
                let section = BookSection(id: sections.count, chapterIndex: index, elementID: pageID, text: text)
                sections.append(section)
                for range in ranges {
                    sentences.append(SpeechSentence(id: sentences.count, sectionID: section.id, range: range, chapterIndex: index))
                }
                if languageSample.count < 4096 {
                    languageSample += String(text.prefix(4096 - languageSample.count))
                }
            }
            let now = ProcessInfo.processInfo.systemUptime
            if index + 1 == pageCount || now - lastUpdate >= 0.1 {
                progress(ImportProgress(stage: .indexing, completed: Int64(index + 1), total: Int64(pageCount)))
                lastUpdate = now
            }
        }

        try Task.checkCancellation()
        let cover = writeCover(of: document, in: source.deletingLastPathComponent())
        let language = NLLanguageRecognizer.dominantLanguage(for: languageSample)?.rawValue ?? "zh-CN"
        let record = BookRecord(id: id, title: title, author: author, language: language, coverPath: cover,
                                chapterCount: pageCount, sentenceCount: sentences.count, format: .pdf)
        return SpeechBook(record: record, chapters: chapters, sections: sections, sentences: sentences, contents: contents)
    }

    private static func metadataText(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(2048))
    }

    private static func writeCover(of document: PDFDocument, in directory: URL) -> String? {
        guard let page = document.page(at: 0) else { return nil }
        let thumbnail = page.thumbnail(of: CGSize(width: 240, height: 320), for: .cropBox)
        #if os(iOS)
        let data = thumbnail.pngData()
        #else
        let data = thumbnail.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        #endif
        guard let data else { return nil }
        let name = "cover.png"
        do {
            try data.write(to: directory.appendingPathComponent(name), options: bookDataWriteOptions)
            return name
        } catch { return nil }
    }
}
