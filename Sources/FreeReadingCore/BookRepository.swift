import Foundation
import CryptoKit

/// 应用私有书库；目录修改串行执行，耗时解包和索引读写不会占用阅读进度的 actor 通道。
public actor BookRepository {
    public nonisolated let root: URL
    private let files = FileManager.default
    private let mutationGate: RepositoryMutationGate
    private nonisolated let readingSaves = ReadingSaveRegistry()
    private var cachedBook: SpeechBook?
    private var cachedReading: ReadingBook?
    private struct SpeechLoad { var generation: Date; var token: UUID; var task: Task<BookIndexIO.Loaded, Error> }
    private var speechLoads: [String: SpeechLoad] = [:]
    private struct ProgressEntry { var generation: Date; var value: ReadingProgress; var dirty: Bool }
    private var progressCache: [String: ProgressEntry] = [:]
    private struct PDFReadingPage: Codable {
        let index: Int
        let addedAt: Date
        let updatedAt: Date
    }

    public init(root: URL? = nil) throws {
        let base = try root ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("FreeReading", isDirectory: true)
        // 先建立根目录再解析符号链接；Darwin 对尚不存在的叶目录可能保留 /var 别名。
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let canonical = base.standardizedFileURL.resolvingSymlinksInPath()
        self.root = canonical
        self.mutationGate = RepositoryProcessState.shared.gate(for: canonical)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: canonical.path)
        #endif
        try FileManager.default.createDirectory(at: canonical.appendingPathComponent("books"), withIntermediateDirectories: true)
        RepositoryProcessState.shared.recoverTemporaryDirectories(in: canonical)
    }

    /// 书架只读取小型记录；单本损坏不会阻塞其余书籍。
    public func books() throws -> [BookRecord] {
        try files.contentsOfDirectory(at: root.appendingPathComponent("books"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .compactMap { try? record(id: $0.lastPathComponent) }.sorted { $0.addedAt > $1.addedAt }
    }

    /// 复制、解包及逐项索引写入在独立任务完成；只有目录重命名成功才报告 completed。
    public func importEPUB(from source: URL, progress: @Sendable @escaping (ImportProgress) -> Void = { _ in }) async throws -> SpeechBook {
        guard source.isFileURL else { throw BookError.invalid("请选择本地 EPUB 文件") }
        return try await importDocument(from: source, format: .epub, progress: progress)
    }

    public func importDocument(from source: URL, progress: @Sendable @escaping (ImportProgress) -> Void = { _ in }) async throws -> SpeechBook {
        guard let format = BookFormat(fileURL: source) else { throw BookError.invalid("请选择本地 EPUB 或 PDF 文件") }
        return try await importDocument(from: source, format: format, progress: progress)
    }

    private func importDocument(from source: URL, format: BookFormat, progress: @Sendable @escaping (ImportProgress) -> Void) async throws -> SpeechBook {
        let lease = try await mutationGate.acquire()
        do {
            try Task.checkCancellation()
            let base = root
            let book = try await Self.worker { try Self.importBook(from: source, format: format, root: base, progress: progress) }
            // 删除使用同一目录锁，因此成功导入不会被另一操作在缓存提交前移走。
            cachedBook = book; cachedReading = ReadingBook(book: book)
            await mutationGate.release(lease)
            return book
        } catch {
            await mutationGate.release(lease)
            throw error
        }
    }

    /// 同步登记退出保存，避免 UI 离开后才排入任务导致快速重开读到旧位置。
    public nonisolated func registerReadingSave(bookID: String, expectedAddedAt: Date, task: Task<Void, Never>) {
        readingSaves.register(bookID: bookID, addedAt: expectedAddedAt, task: task)
    }

    /// 新书只加载阅读目录；旧 v1 书库首次打开时流式提取目录，不解码完整句子数组。
    public func prepareReadingBook(id: String) async throws -> ReadingBookBootstrap {
        let metadata = try record(id: id)
        while true {
            let pending = readingSaves.pending(bookID: id, addedAt: metadata.addedAt)
            if pending.isEmpty { break }
            for entry in pending { await entry.task.value }
            readingSaves.finish(Set(pending.map(\.id)))
            try Task.checkCancellation()
            guard try record(id: id) == metadata else { throw BookError.invalid("书籍已被移除或重新导入") }
        }
        try Task.checkCancellation()
        let reading: ReadingBook
        if let cachedReading, cachedReading.record == metadata { reading = cachedReading }
        else {
            let directory = bookDirectory(id: id)
            let catalog = directory.appendingPathComponent("reading.json")
            if files.fileExists(atPath: catalog.path) {
                reading = try await Self.worker {
                    let result = try BookIndexIO.readJSON(ReadingBook.self, from: catalog, limit: BookIndexIO.catalogLimit)
                    try Self.validateReading(result, metadata: metadata, directory: directory)
                    return result
                }
            } else {
                // 只有旧库的一次性目录补建需要修改锁；等待最终保存时从不持有此锁。
                let lease = try await mutationGate.acquire()
                do {
                    try Task.checkCancellation()
                    guard try record(id: id) == metadata else { throw BookError.invalid("书籍已被移除或重新导入") }
                    reading = try await Self.worker {
                        let result = try BookIndexIO.legacyReading(directory: directory, metadata: metadata)
                        try Self.validateReading(result, metadata: metadata, directory: directory)
                        // 目录是可重建的缓存。磁盘满或只读时仍交付已验证的旧书目录，下次打开再补写。
                        do { try BookIndexIO.writeJSON(result, to: catalog, limit: BookIndexIO.catalogLimit) }
                        catch is CancellationError { throw CancellationError() }
                        catch { try Task.checkCancellation() }
                        try Task.checkCancellation()
                        return result
                    }
                    await mutationGate.release(lease)
                } catch { await mutationGate.release(lease); throw error }
            }
        }
        try Task.checkCancellation()
        guard try record(id: id) == metadata else { throw BookError.invalid("书籍已被移除或重新导入") }
        cachedReading = reading
        return ReadingBookBootstrap(book: reading, progress: try readingProgress(bookID: id),
            cachedSpeechBook: cachedBook?.record == metadata ? cachedBook : nil,
            pdfPage: storedPDFReadingPage(for: metadata)?.index)
    }

    /// 相同导入批次的并发请求共享解码任务；不等待最终阅读保存，以免保存任务等待自己。
    public func loadSpeechBook(id: String) async throws -> SpeechBook {
        let metadata = try record(id: id)
        if let cachedBook, cachedBook.record == metadata { return cachedBook }
        let load: SpeechLoad
        if let existing = speechLoads[id], existing.generation == metadata.addedAt { load = existing }
        else {
            speechLoads[id]?.task.cancel()
            let directory = bookDirectory(id: id)
            let task = Task.detached(priority: .userInitiated) {
                let result = try BookIndexIO.load(directory: directory, metadata: metadata)
                try Self.validate(result.book, metadata: metadata, directory: directory)
                return result
            }
            load = SpeechLoad(generation: metadata.addedAt, token: UUID(), task: task)
            speechLoads[id] = load
        }
        do {
            let result = try await load.task.value
            try Task.checkCancellation()
            guard try record(id: id) == metadata else { throw BookError.invalid("书籍已被移除或重新导入") }
            if result.legacy { try await migrateLegacy(result.book) }
            guard try record(id: id) == metadata else { throw BookError.invalid("书籍已被移除或重新导入") }
            cachedBook = result.book
            if cachedReading?.record != metadata { cachedReading = ReadingBook(book: result.book) }
            if speechLoads[id]?.token == load.token { speechLoads[id] = nil }
            return result.book
        } catch {
            // 某个调用者取消不应取消仍被播放器或另一页面共享的解码任务。
            if !(error is CancellationError), speechLoads[id]?.token == load.token { speechLoads[id] = nil }
            throw error
        }
    }

    /// 保留旧调用方的完整索引加载入口。
    public func loadBook(id: String) async throws -> SpeechBook { try await loadSpeechBook(id: id) }

    public func readingProgress(bookID: String) throws -> ReadingProgress? {
        let metadata = try record(id: bookID)
        if progressCache[bookID]?.generation != metadata.addedAt { progressCache[bookID] = nil }
        let url = bookDirectory(id: bookID).appendingPathComponent("progress.json")
        if let disk = try? BookIndexIO.readJSON(ReadingProgress.self, from: url, limit: 128 * 1024),
           disk.bookID == bookID, disk.updatedAt >= metadata.addedAt, Self.validProgress(disk, metadata: metadata),
           progressCache[bookID].map({ $0.value.updatedAt < disk.updatedAt }) ?? true {
            progressCache[bookID] = ProgressEntry(generation: metadata.addedAt, value: disk, dirty: false)
        }
        guard var entry = progressCache[bookID] else { return nil }
        if entry.dirty {
            // 短暂磁盘故障后在下次读取或保存时重试；失败期间仍返回最新内存游标。
            if (try? BookIndexIO.writeJSON(entry.value, to: url, limit: 128 * 1024)) != nil {
                entry.dirty = false; progressCache[bookID] = entry
            }
        }
        return entry.value
    }

    /// PDF 阅读页独立保存，暂停时换页也不会覆盖音频句子或句内进度。
    public func savePDFReadingPage(bookID: String, index: Int, expectedAddedAt: Date, updatedAt: Date = Date()) throws {
        guard let metadata = try? record(id: bookID), metadata.format == .pdf, metadata.addedAt == expectedAddedAt,
              (0..<metadata.chapterCount).contains(index), updatedAt >= metadata.addedAt,
              updatedAt.timeIntervalSinceReferenceDate.isFinite else { return }
        if let previous = storedPDFReadingPage(for: metadata), previous.updatedAt > updatedAt { return }
        let position = PDFReadingPage(index: index, addedAt: metadata.addedAt, updatedAt: updatedAt)
        try BookIndexIO.writeJSON(position, to: pdfPageFile(bookID), limit: 4096)
    }

    private func storedPDFReadingPage(for metadata: BookRecord) -> PDFReadingPage? {
        guard metadata.format == .pdf,
              let position = try? BookIndexIO.readJSON(PDFReadingPage.self, from: pdfPageFile(metadata.id), limit: 4096),
              position.addedAt == metadata.addedAt, position.updatedAt >= metadata.addedAt,
              position.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              (0..<metadata.chapterCount).contains(position.index) else { return nil }
        return position
    }

    private func pdfPageFile(_ bookID: String) -> URL {
        bookDirectory(id: bookID).appendingPathComponent("pdf-page.json")
    }

    /// 内存先接受最新合法位置，原子写盘失败仍可恢复；导入时间隔离删除后重导入的同哈希书籍。
    public func saveProgress(_ value: ReadingProgress, expectedAddedAt: Date? = nil) throws {
        guard let metadata = try? record(id: value.bookID), value.updatedAt >= metadata.addedAt,
              expectedAddedAt == nil || expectedAddedAt == metadata.addedAt, Self.validProgress(value, metadata: metadata) else { return }
        if let existing = try readingProgress(bookID: value.bookID), existing.updatedAt > value.updatedAt { return }
        progressCache[value.bookID] = ProgressEntry(generation: metadata.addedAt, value: value, dirty: true)
        try BookIndexIO.writeJSON(value, to: bookDirectory(id: value.bookID).appendingPathComponent("progress.json"), limit: 128 * 1024)
        progressCache[value.bookID]?.dirty = false
    }

    /// 先把目录移出书架，再清理文件；迟到的索引结果与进度保存都不能复活书籍。
    public func removeBook(id: String) async throws {
        try Self.requireID(id)
        let lease = try await mutationGate.acquire()
        do {
            try Task.checkCancellation()
            let directory = bookDirectory(id: id)
            if files.fileExists(atPath: directory.path) {
                let trash = root.appendingPathComponent(".trash-" + UUID().uuidString, isDirectory: true)
                RepositoryProcessState.shared.activate(trash)
                do { try files.moveItem(at: directory, to: trash) }
                catch { RepositoryProcessState.shared.deactivate(trash); throw error }
                speechLoads.removeValue(forKey: id)?.task.cancel()
                if cachedBook?.record.id == id { cachedBook = nil }
                if cachedReading?.record.id == id { cachedReading = nil }
                progressCache[id] = nil; readingSaves.remove(bookID: id)
                // 删除已提交，不因后续取消或回收失败把书籍放回书架。
                await Task.detached(priority: .utility) {
                    defer { RepositoryProcessState.shared.deactivate(trash) }
                    try? FileManager.default.removeItem(at: trash)
                }.value
            }
            await mutationGate.release(lease)
        } catch { await mutationGate.release(lease); throw error }
    }

    public nonisolated func bookDirectory(id: String) -> URL {
        let safeID = id.count == 64 && id.allSatisfy { $0.isASCII && $0.isHexDigit } ? id.lowercased() : "invalid-book-id"
        return root.appendingPathComponent("books", isDirectory: true).appendingPathComponent(safeID, isDirectory: true)
    }
    public nonisolated func contentURL(bookID: String, href: String) throws -> URL {
        try Self.requireID(bookID)
        return try EPUBPath.file(href, in: bookDirectory(id: bookID).appendingPathComponent("content", isDirectory: true))
    }

    /// 返回书库内保留的原始 PDF，避免直接打开原来源或越界文件。
    public nonisolated func pdfURL(bookID: String) throws -> URL {
        try Self.requireID(bookID)
        return try Self.pdfFile(in: bookDirectory(id: bookID))
    }

    private static func requireID(_ id: String) throws {
        guard id.count == 64, id.allSatisfy({ $0.isASCII && $0.isHexDigit }), id == id.lowercased() else { throw BookError.invalid("书籍标识无效") }
    }
    private func record(id: String) throws -> BookRecord { try Self.readRecord(id: id, directory: bookDirectory(id: id)) }
    private static func readRecord(id: String, directory: URL) throws -> BookRecord {
        try requireID(id)
        let value = try BookIndexIO.readJSON(BookRecord.self, from: directory.appendingPathComponent("book.json"), limit: 128 * 1024)
        guard value.id == id, value.addedAt.timeIntervalSinceReferenceDate.isFinite,
              value.chapterCount > 0, value.chapterCount <= BookLimits.resources,
              value.sentenceCount >= (value.format == .pdf ? 0 : 1),
              value.sentenceCount <= BookLimits.sentences else { throw BookError.invalid("书籍记录损坏") }
        if let cover = value.coverPath { _ = try EPUBPath.file(cover, in: directory) }
        return value
    }

    private func migrateLegacy(_ book: SpeechBook) async throws {
        let lease = try await mutationGate.acquire()
        do {
            try Task.checkCancellation()
            guard try record(id: book.record.id) == book.record else { throw BookError.invalid("书籍已被移除或重新导入") }
            let directory = bookDirectory(id: book.record.id)
            let header = try? BookIndexIO.readJSON(BookIndexIO.Header.self, from: directory.appendingPathComponent("index.json"), limit: 16 * 1024)
            if header?.version != 2 {
                try await Self.worker {
                    // 原 v1 已完整读取和验证，升级写盘失败只延后缓存迁移，不阻止现有书籍听读。
                    do { try BookIndexIO.write(book, directory: directory) }
                    catch is CancellationError { throw CancellationError() }
                    catch { try Task.checkCancellation() }
                }
            }
            try Task.checkCancellation()
            guard try record(id: book.record.id) == book.record else { throw BookError.invalid("书籍已被移除或重新导入") }
            await mutationGate.release(lease)
        } catch { await mutationGate.release(lease); throw error }
    }

    /// 阅读目录独立校验，损坏的听书分片不会妨碍用户打开原文。
    private static func validateReading(_ book: ReadingBook, metadata: BookRecord, directory: URL) throws {
        guard book.record == metadata, book.chapters.count == metadata.chapterCount,
              book.chapterWeights.count == book.chapters.count,
              book.chapterWeights.allSatisfy({ $0.isFinite && $0 >= 0 }),
              book.chapterWeights.reduce(0, +) <= Double(BookLimits.textCharacters),
              book.contents.count <= BookLimits.resources else { throw BookError.invalid("阅读目录与书籍不一致") }
        if metadata.format == .pdf { _ = try pdfFile(in: directory) }
        for (index, chapter) in book.chapters.enumerated() {
            guard chapter.id == index else { throw BookError.invalid("章节顺序损坏") }
            if metadata.format == .pdf {
                guard chapter.href == PDFImporter.pageIdentifier(index) else { throw BookError.invalid("PDF 页索引损坏") }
                continue
            }
            let file = try EPUBPath.file(chapter.href, in: directory.appendingPathComponent("content"))
            guard FileManager.default.fileExists(atPath: file.path) else { throw BookError.invalid("正文文件已丢失，请重新导入") }
        }
        guard book.contents.allSatisfy({ book.chapters.indices.contains($0.chapterIndex) && $0.depth >= 0 && $0.depth < 128 }) else { throw BookError.invalid("目录索引损坏") }
    }

    private static func pdfFile(in directory: URL) throws -> URL {
        let file = try EPUBPath.file(BookFormat.pdf.storedFileName, in: directory)
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw BookError.invalid("PDF 原文件已丢失，请重新导入")
        }
        return file
    }

    /// 完整加载后检查每个 UTF-16 范围，避免损坏的索引导致正文或播放器越界。
    private static func validate(_ book: SpeechBook, metadata: BookRecord, directory: URL) throws {
        guard book.sentences.count == metadata.sentenceCount,
              !book.sections.isEmpty || (metadata.format == .pdf && book.sentences.isEmpty),
              book.sections.count <= BookLimits.sentences else { throw BookError.invalid("听书索引与书籍不一致") }
        try validateReading(ReadingBook(book: book), metadata: metadata, directory: directory)
        var characters = 0
        var previousPDFPage = -1
        for (index, section) in book.sections.enumerated() {
            guard section.id == index, book.chapters.indices.contains(section.chapterIndex), section.text.utf16.count <= BookLimits.textCharacters - characters else { throw BookError.invalid("原文片段索引损坏") }
            if metadata.format == .pdf {
                guard section.chapterIndex > previousPDFPage, section.elementID == PDFImporter.pageIdentifier(section.chapterIndex) else {
                    throw BookError.invalid("PDF 文本页索引损坏")
                }
                previousPDFPage = section.chapterIndex
            }
            characters += section.text.utf16.count
        }
        var lastChapter = 0; var lastSection = -1; var units: [UInt16] = []
        for (index, sentence) in book.sentences.enumerated() {
            if index % 1024 == 0 { try Task.checkCancellation() }
            guard sentence.id == index, book.sections.indices.contains(sentence.sectionID), sentence.chapterIndex >= lastChapter, sentence.sectionID >= lastSection else { throw BookError.invalid("句子顺序损坏") }
            let section = book.sections[sentence.sectionID]
            if sentence.sectionID != lastSection { units = Array(section.text.utf16); lastSection = sentence.sectionID }
            let range = sentence.range
            guard sentence.chapterIndex == section.chapterIndex, range.start >= 0, range.end > range.start, range.end <= units.count, range.end - range.start <= 500,
                  isBoundary(range.start, units), isBoundary(range.end, units) else { throw BookError.invalid("句子范围损坏") }
            lastChapter = sentence.chapterIndex
        }
    }
    private static func isBoundary(_ offset: Int, _ text: [UInt16]) -> Bool {
        offset == 0 || offset == text.count || !((0xD800...0xDBFF).contains(text[offset - 1]) && (0xDC00...0xDFFF).contains(text[offset]))
    }
    private static func validProgress(_ value: ReadingProgress, metadata: BookRecord) -> Bool {
        let sentenceCount = metadata.format == .pdf ? max(1, metadata.sentenceCount) : metadata.sentenceCount
        return value.chapterIndex >= 0 && value.chapterIndex < metadata.chapterCount && value.sentenceIndex >= 0 && value.sentenceIndex < sentenceCount && value.textOffset >= 0 && value.audioOffset.isFinite && value.audioOffset >= 0 && value.pageProgress.isFinite && (0...1).contains(value.pageProgress) && value.updatedAt.timeIntervalSinceReferenceDate.isFinite
    }

    /// 取消显式传给独立的 IO 任务，解包器及流式编码器的取消检查才能及时生效。
    private static func worker<T: Sendable>(_ body: @Sendable @escaping () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: body)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func importBook(from source: URL, format: BookFormat, root: URL, progress: @Sendable (ImportProgress) -> Void) throws -> SpeechBook {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let files = FileManager.default
        let staging = root.appendingPathComponent("books/.import-" + UUID().uuidString, isDirectory: true)
        RepositoryProcessState.shared.activate(staging)
        defer { try? files.removeItem(at: staging); RepositoryProcessState.shared.deactivate(staging) }
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        let copied = staging.appendingPathComponent(format.storedFileName)
        let id = try copyAndHash(source, to: copied, format: format, progress: progress)
        let destination = root.appendingPathComponent("books/" + id, isDirectory: true)
        try Task.checkCancellation()
        if files.fileExists(atPath: destination.appendingPathComponent("book.json").path) {
            let metadata = try readRecord(id: id, directory: destination)
            guard (metadata.format ?? .epub) == format else { throw BookError.invalid("文件内容与所选书籍格式不一致") }
            let book = try BookIndexIO.load(directory: destination, metadata: metadata).book
            try validate(book, metadata: metadata, directory: destination)
            try Task.checkCancellation()
            progress(ImportProgress(stage: .completed, completed: 1, total: 1)); return book
        }
        let book: SpeechBook
        switch format {
        case .epub:
            book = try EPUBImporter().open(source: copied, contentRoot: staging.appendingPathComponent("content", isDirectory: true), id: id, progress: progress)
        case .pdf:
            book = try PDFImporter.open(source: copied, suggestedTitle: source.deletingPathExtension().lastPathComponent, id: id, progress: progress)
        }
        progress(ImportProgress(stage: .saving, completed: 0, total: 2))
        try BookIndexIO.write(book, directory: staging)
        progress(ImportProgress(stage: .saving, completed: 1, total: 2))
        try BookIndexIO.writeJSON(book.record, to: staging.appendingPathComponent("book.json"), limit: 128 * 1024)
        try Task.checkCancellation()
        guard !files.fileExists(atPath: destination.path) else { throw BookError.invalid("已有同名书籍目录损坏，请先移除后重试") }
        try files.moveItem(at: staging, to: destination)
        progress(ImportProgress(stage: .saving, completed: 2, total: 2))
        progress(ImportProgress(stage: .completed, completed: 1, total: 1))
        return book
    }
    private static func copyAndHash(_ source: URL, to destination: URL, format: BookFormat, progress: @Sendable (ImportProgress) -> Void) throws -> String {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let declared = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let formatName = format.rawValue.uppercased()
        if let declared, Int64(declared) > BookLimits.sourceBytes { throw BookError.invalid("\(formatName) 文件超过 100 MB") }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw BookError.invalid("无法建立导入暂存文件") }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hasher = SHA256(); var count: Int64 = 0
        progress(ImportProgress(stage: .copying, completed: 0, total: declared.map(Int64.init)))
        var previousNotification = Date.distantPast
        while let chunk = try input.read(upToCount: 128 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            count += Int64(chunk.count)
            guard count <= BookLimits.sourceBytes else { throw BookError.invalid("\(formatName) 文件超过 100 MB") }
            hasher.update(data: chunk); try output.write(contentsOf: chunk)
            if Date().timeIntervalSince(previousNotification) >= 0.1 {
                progress(ImportProgress(stage: .copying, completed: count, total: declared.map(Int64.init))); previousNotification = Date()
            }
        }
        guard count > 0 else { throw BookError.invalid("\(formatName) 文件为空") }
        try output.synchronize()
        progress(ImportProgress(stage: .copying, completed: count, total: count))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

}
