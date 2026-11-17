import Foundation
import CryptoKit

/// 应用级书库，串行化导入、删除和进度提交；所有原文件与索引保存在应用私有目录。
public actor BookRepository {
    public nonisolated let root: URL
    private let files = FileManager.default
    private var cachedBook: SpeechBook?

    public init(root: URL? = nil) throws {
        let base = try root ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("FreeReading", isDirectory: true)
        self.root = base.standardizedFileURL
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: base.path)
        #endif
        try FileManager.default.createDirectory(at: base.appendingPathComponent("books"), withIntermediateDirectories: true)
    }

    /// 忽略损坏的单本书记录，不让它阻塞其余书架；索引只在打开书籍时读取。
    public func books() throws -> [BookRecord] {
        try files.contentsOfDirectory(at: root.appendingPathComponent("books"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .compactMap { directory in try? record(id: directory.lastPathComponent) }
            .sorted { $0.addedAt > $1.addedAt }
    }

    /// 一次读取来源完成复制与哈希；在暂存目录成功建索引后，重命名目录作为书架提交点。
    public func importEPUB(from source: URL, progress: @Sendable (ImportProgress) -> Void = { _ in }) throws -> SpeechBook {
        guard source.isFileURL else { throw BookError.invalid("请选择本地 EPUB 文件") }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let staging = root.appendingPathComponent("books/.import-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        let copied = staging.appendingPathComponent("book.epub")
        let id = try copyAndHash(source, to: copied, progress: progress)
        try Task.checkCancellation()
        if files.fileExists(atPath: bookDirectory(id: id).appendingPathComponent("book.json").path) {
            let existing = try loadBook(id: id)
            progress(ImportProgress(stage: .completed, completed: 1, total: 1))
            return existing
        }
        let book = try EPUBImporter().open(source: copied, contentRoot: staging.appendingPathComponent("content", isDirectory: true), id: id, progress: progress)
        progress(ImportProgress(stage: .saving, completed: 0, total: 2))
        try writeJSON(book, to: staging.appendingPathComponent("index.json"), limit: BookLimits.indexBytes)
        progress(ImportProgress(stage: .saving, completed: 1, total: 2))
        try writeJSON(book.record, to: staging.appendingPathComponent("book.json"), limit: 128 * 1024)
        try Task.checkCancellation()
        let destination = bookDirectory(id: id)
        // 若上次异常只留下损坏目录，不覆盖它；保留证据并提示用户先移除记录。
        guard !files.fileExists(atPath: destination.path) else { throw BookError.invalid("已有同名书籍目录损坏，请先移除后重试") }
        try files.moveItem(at: staging, to: destination)
        cachedBook = book
        progress(ImportProgress(stage: .saving, completed: 2, total: 2))
        progress(ImportProgress(stage: .completed, completed: 1, total: 1))
        return book
    }

    /// 只保留最近打开的一本索引；长书不会因多次阅读而在内存中累计多份正文。
    public func loadBook(id: String) throws -> SpeechBook {
        let metadata = try record(id: id)
        if let cachedBook, cachedBook.record == metadata { return cachedBook }
        let book = try readJSON(SpeechBook.self, from: bookDirectory(id: id).appendingPathComponent("index.json"), limit: BookLimits.indexBytes)
        try validate(book, metadata: metadata)
        cachedBook = book
        return book
    }

    public func readingProgress(bookID: String) throws -> ReadingProgress? {
        let metadata = try record(id: bookID)
        let url = bookDirectory(id: bookID).appendingPathComponent("progress.json")
        guard files.fileExists(atPath: url.path), let value = try? readJSON(ReadingProgress.self, from: url, limit: 128 * 1024), value.bookID == bookID, value.updatedAt >= metadata.addedAt, validProgress(value, metadata: metadata) else { return nil }
        return value
    }

    /// 拒绝旧时间戳及已移除书籍的保存；调用方可传入导入时间，隔离移除后重导入的同哈希书籍。
    public func saveProgress(_ value: ReadingProgress, expectedAddedAt: Date? = nil) throws {
        guard let metadata = try? record(id: value.bookID) else { return }
        guard value.updatedAt >= metadata.addedAt, expectedAddedAt == nil || expectedAddedAt == metadata.addedAt,
              validProgress(value, metadata: metadata) else { return }
        if let existing = try readingProgress(bookID: value.bookID), existing.updatedAt > value.updatedAt { return }
        try writeJSON(value, to: bookDirectory(id: value.bookID).appendingPathComponent("progress.json"), limit: 128 * 1024)
    }

    /// 先将目录移出书架，再删除文件；暂停后的迟到保存无法重新创建该目录。
    public func removeBook(id: String) throws {
        try requireID(id)
        let directory = bookDirectory(id: id)
        guard files.fileExists(atPath: directory.path) else { return }
        let trash = root.appendingPathComponent(".trash-" + UUID().uuidString, isDirectory: true)
        try files.moveItem(at: directory, to: trash)
        if cachedBook?.record.id == id { cachedBook = nil }
        try? files.removeItem(at: trash)
    }

    /// UI 只用已经校验的书籍 ID 构造沙盒 URL；非法输入不允许逃离 books 目录。
    public nonisolated func bookDirectory(id: String) -> URL {
        let safeID = id.count == 64 && id.allSatisfy { $0.isASCII && $0.isHexDigit } ? id.lowercased() : "invalid-book-id"
        return root.appendingPathComponent("books", isDirectory: true).appendingPathComponent(safeID, isDirectory: true)
    }

    public nonisolated func contentURL(bookID: String, href: String) throws -> URL {
        try requireID(bookID)
        return try EPUBPath.file(href, in: bookDirectory(id: bookID).appendingPathComponent("content", isDirectory: true))
    }

    private nonisolated func requireID(_ id: String) throws {
        guard id.count == 64, id.allSatisfy({ $0.isASCII && $0.isHexDigit }), id == id.lowercased() else { throw BookError.invalid("书籍标识无效") }
    }

    private func record(id: String) throws -> BookRecord {
        try requireID(id)
        let value = try readJSON(BookRecord.self, from: bookDirectory(id: id).appendingPathComponent("book.json"), limit: 128 * 1024)
        guard value.id == id, value.chapterCount > 0, value.chapterCount <= BookLimits.resources, value.sentenceCount > 0, value.sentenceCount <= BookLimits.sentences else { throw BookError.invalid("书籍记录损坏") }
        if let cover = value.coverPath { _ = try EPUBPath.file(cover, in: bookDirectory(id: id)) }
        return value
    }

    /// 读取后验证每个索引与 UTF-16 范围，避免损坏数据导致 UI 或播放器数组越界。
    private func validate(_ book: SpeechBook, metadata: BookRecord) throws {
        guard book.record == metadata, book.chapters.count == metadata.chapterCount, book.sentences.count == metadata.sentenceCount, !book.sections.isEmpty, book.sections.count <= BookLimits.sentences else { throw BookError.invalid("听书索引与书籍不一致") }
        for (index, chapter) in book.chapters.enumerated() {
            guard chapter.id == index else { throw BookError.invalid("章节顺序损坏") }
            let file = try contentURL(bookID: metadata.id, href: chapter.href)
            guard files.fileExists(atPath: file.path) else { throw BookError.invalid("正文文件已丢失，请重新导入") }
        }
        var characters = 0
        for (index, section) in book.sections.enumerated() {
            guard section.id == index, book.chapters.indices.contains(section.chapterIndex), section.text.utf16.count <= BookLimits.textCharacters - characters else { throw BookError.invalid("原文片段索引损坏") }
            characters += section.text.utf16.count
        }
        var lastChapter = 0
        var lastSection = -1
        var units: [UInt16] = []
        for (index, sentence) in book.sentences.enumerated() {
            guard sentence.id == index, book.sections.indices.contains(sentence.sectionID), sentence.chapterIndex >= lastChapter, sentence.sectionID >= lastSection else { throw BookError.invalid("句子顺序损坏") }
            let section = book.sections[sentence.sectionID]
            if sentence.sectionID != lastSection { units = Array(section.text.utf16); lastSection = sentence.sectionID }
            let range = sentence.range
            guard sentence.chapterIndex == section.chapterIndex, range.start >= 0, range.end > range.start, range.end <= units.count, range.end - range.start <= 500,
                  isBoundary(range.start, units), isBoundary(range.end, units) else { throw BookError.invalid("句子范围损坏") }
            lastChapter = sentence.chapterIndex
        }
        guard book.contents.count <= BookLimits.resources, book.contents.allSatisfy({ book.chapters.indices.contains($0.chapterIndex) && $0.depth >= 0 && $0.depth < 128 }) else { throw BookError.invalid("目录索引损坏") }
    }

    private func isBoundary(_ offset: Int, _ text: [UInt16]) -> Bool {
        offset == 0 || offset == text.count || !((0xD800...0xDBFF).contains(text[offset - 1]) && (0xDC00...0xDFFF).contains(text[offset]))
    }

    private func validProgress(_ value: ReadingProgress, metadata: BookRecord) -> Bool {
        value.chapterIndex >= 0 && value.chapterIndex < metadata.chapterCount && value.sentenceIndex >= 0 && value.sentenceIndex < metadata.sentenceCount && value.textOffset >= 0 && value.audioOffset.isFinite && value.audioOffset >= 0 && value.pageProgress.isFinite && (0...1).contains(value.pageProgress)
    }

    private func copyAndHash(_ source: URL, to destination: URL, progress: @Sendable (ImportProgress) -> Void) throws -> String {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let declared = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize
        if let declared, Int64(declared) > BookLimits.sourceBytes { throw BookError.invalid("EPUB 文件超过 100 MB") }
        guard files.createFile(atPath: destination.path, contents: nil) else { throw BookError.invalid("无法建立导入暂存文件") }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hasher = SHA256(); var count: Int64 = 0
        progress(ImportProgress(stage: .copying, completed: 0, total: declared.map(Int64.init)))
        var previousNotification = Date.distantPast
        while let chunk = try input.read(upToCount: 128 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            count += Int64(chunk.count)
            guard count <= BookLimits.sourceBytes else { throw BookError.invalid("EPUB 文件超过 100 MB") }
            hasher.update(data: chunk); try output.write(contentsOf: chunk)
            if Date().timeIntervalSince(previousNotification) >= 0.1 {
                progress(ImportProgress(stage: .copying, completed: count, total: declared.map(Int64.init))); previousNotification = Date()
            }
        }
        guard count > 0 else { throw BookError.invalid("EPUB 文件为空") }
        try output.synchronize()
        progress(ImportProgress(stage: .copying, completed: count, total: count))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from file: URL, limit: Int) throws -> T {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? limit + 1
        guard size <= limit else { throw BookError.invalid("书籍索引文件超过容量限制") }
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: Data(contentsOf: file))
    }

    /// 写入临时文件再由 Foundation 原子替换，失败不会对外发布成功导入或新游标。
    private func writeJSON<T: Encodable>(_ value: T, to file: URL, limit: Int) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        guard data.count <= limit else { throw BookError.invalid("书籍索引超过可支持容量") }
        try data.write(to: file, options: bookDataWriteOptions)
    }
}
