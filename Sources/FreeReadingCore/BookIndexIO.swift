import Foundation

/// v2 索引只在目录文件中保存计数，正文和句子逐项编码，避免整书 JSON 的临时双份内存。
enum BookIndexIO {
    struct Header: Codable {
        var version = 2
        var sectionCount: Int
        var sentenceCount: Int
        var sections = "sections.jsonl"
        var sentences = "sentences.jsonl"
    }
    struct Loaded: Sendable {
        var book: SpeechBook
        var legacy: Bool
        /// 流读取临时缓冲的上界，不包含最终返回的共享正文数组。
        var peakBufferedBytes: Int
    }
    static let catalogLimit = 32 * 1024 * 1024
    private static let lineReadChunkBytes = 64 * 1024
    // 旧版最多接受 12 MiB 待续字节加一个读取块内换行前的字节，保留这一上限。
    static let lineByteLimit = 12 * 1024 * 1024 + lineReadChunkBytes - 1

    static func write(_ book: SpeechBook, directory: URL) throws {
        try Task.checkCancellation()
        let sectionBytes = try writeLines(book.sections, to: directory.appendingPathComponent("sections.jsonl"))
        let sentenceBytes = try writeLines(book.sentences, to: directory.appendingPathComponent("sentences.jsonl"))
        guard sectionBytes <= BookLimits.indexBytes - sentenceBytes else { throw BookError.invalid("书籍索引超过可支持容量") }
        try writeJSON(ReadingBook(book: book), to: directory.appendingPathComponent("reading.json"), limit: catalogLimit)
        // 最后原子提交小型头文件；迁移中断时原 v1 索引仍可读取。
        try Task.checkCancellation()
        try writeJSON(Header(sectionCount: book.sections.count, sentenceCount: book.sentences.count), to: directory.appendingPathComponent("index.json"), limit: 16 * 1024)
    }

    static func load(directory: URL, metadata: BookRecord) throws -> Loaded {
        let index = directory.appendingPathComponent("index.json")
        if try size(index) <= 16 * 1024,
           let header = try? readJSON(Header.self, from: index, limit: 16 * 1024) {
            guard header.version == 2, header.sections == "sections.jsonl", header.sentences == "sentences.jsonl",
                  header.sectionCount >= (metadata.format == .pdf && metadata.sentenceCount == 0 ? 0 : 1),
                  header.sectionCount <= BookLimits.sentences,
                  header.sentenceCount == metadata.sentenceCount else { throw BookError.invalid("听书索引版本或计数损坏") }
            let reading = try readJSON(ReadingBook.self, from: directory.appendingPathComponent("reading.json"), limit: catalogLimit)
            let sectionFile = directory.appendingPathComponent(header.sections)
            let sentenceFile = directory.appendingPathComponent(header.sentences)
            guard try size(sectionFile) + size(sentenceFile) <= BookLimits.indexBytes else { throw BookError.invalid("书籍索引文件超过容量限制") }
            let (sections, firstPeak) = try readLines(BookSection.self, from: sectionFile, count: header.sectionCount)
            let (sentences, secondPeak) = try readLines(SpeechSentence.self, from: sentenceFile, count: header.sentenceCount)
            return Loaded(book: SpeechBook(record: reading.record, chapters: reading.chapters, sections: sections, sentences: sentences, contents: reading.contents), legacy: false, peakBufferedBytes: max(firstPeak, secondPeak))
        }
        return try legacy(directory: directory, metadata: metadata, readingOnly: false).loaded!
    }

    /// 旧版首次开书只逐项提取目录和章节权重，跳过句子数组，不建立完整听书对象。
    static func legacyReading(directory: URL, metadata: BookRecord) throws -> ReadingBook {
        try legacy(directory: directory, metadata: metadata, readingOnly: true).reading
    }

    private static func legacy(directory: URL, metadata: BookRecord, readingOnly: Bool) throws -> (reading: ReadingBook, loaded: Loaded?) {
        let reader = try JSONValueStream(directory.appendingPathComponent("index.json"), limit: BookLimits.indexBytes)
        var stored: BookRecord?
        var chapters: [BookChapter]?
        var contents: [ContentsEntry]?
        var sections: [BookSection] = []
        var sentences: [SpeechSentence] = []
        var weights = Array(repeating: 0.0, count: metadata.chapterCount)
        var characters = 0
        var sectionCount = 0
        var sentenceCount = 0
        try reader.object { key in
            switch key {
            case "record": stored = try reader.decodeValue(BookRecord.self, limit: 128 * 1024)
            case "chapters": chapters = try reader.decodeValue([BookChapter].self, limit: catalogLimit)
            case "contents": contents = try reader.decodeValue([ContentsEntry].self, limit: catalogLimit)
            case "sections":
                try reader.array(limit: BookLimits.sentences) {
                    let section = try reader.decodeValue(BookSection.self, limit: 12 * 1024 * 1024)
                    guard section.id == sectionCount, weights.indices.contains(section.chapterIndex), section.text.utf16.count <= BookLimits.textCharacters - characters else { throw BookError.invalid("原文片段索引损坏") }
                    characters += section.text.utf16.count
                    weights[section.chapterIndex] += Double(section.text.utf16.count)
                    sectionCount += 1
                    if !readingOnly { sections.append(section) }
                }
            case "sentences":
                try reader.array(limit: BookLimits.sentences) {
                    sentenceCount += 1
                    if readingOnly { try reader.skipValue() }
                    else { sentences.append(try reader.decodeValue(SpeechSentence.self, limit: 4096)) }
                }
            default: try reader.skipValue()
            }
        }
        guard stored == metadata, let chapters, let contents, sectionCount > 0, sentenceCount == metadata.sentenceCount else { throw BookError.invalid("听书索引与书籍不一致") }
        let reading = ReadingBook(record: metadata, chapters: chapters, contents: contents, chapterWeights: weights)
        if readingOnly { return (reading, nil) }
        return (reading, Loaded(book: SpeechBook(record: metadata, chapters: chapters, sections: sections, sentences: sentences, contents: contents), legacy: true, peakBufferedBytes: reader.peakBufferedBytes))
    }

    static func readJSON<T: Decodable>(_ type: T.Type, from file: URL, limit: Int) throws -> T {
        guard try size(file) <= limit else { throw BookError.invalid("书籍索引文件超过容量限制") }
        return try JSONDecoder().decode(type, from: Data(contentsOf: file))
    }

    static func writeJSON<T: Encodable>(_ value: T, to file: URL, limit: Int) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= limit else { throw BookError.invalid("书籍索引超过可支持容量") }
        try data.write(to: file, options: bookDataWriteOptions)
    }

    private static func size(_ file: URL) throws -> Int {
        let count = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard count >= 0 else { throw BookError.invalid("书籍索引文件大小无效") }
        return count
    }

    private static func writeLines<T: Encodable>(_ values: [T], to file: URL) throws -> Int {
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".index-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw BookError.invalid("无法建立听书索引") }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        var total = 0
        var buffer = Data()
        let encoder = JSONEncoder()
        for value in values {
            try Task.checkCancellation()
            var data = try encoder.encode(value)
            guard data.count <= lineByteLimit else { throw BookError.invalid("听书索引单项过大") }
            data.append(10)
            guard data.count <= BookLimits.indexBytes - total else { throw BookError.invalid("书籍索引超过可支持容量") }
            total += data.count
            buffer.append(data)
            if buffer.count >= 64 * 1024 { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        try handle.synchronize()
        try Task.checkCancellation()
        // POSIX rename 原子替换已有分片，旧 v1 迁移被取消后可安全重试。
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: file) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        #endif
        return total
    }

    private static func readLines<T: Decodable>(_ type: T.Type, from file: URL, count: Int) throws -> ([T], Int) {
        guard try size(file) <= BookLimits.indexBytes else { throw BookError.invalid("书籍索引文件超过容量限制") }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var values: [T] = []; values.reserveCapacity(count)
        var pending = Data()
        var peak = 0
        let decoder = JSONDecoder()
        while let chunk = try input.read(upToCount: lineReadChunkBytes), !chunk.isEmpty {
            try Task.checkCancellation()
            let bufferedBytes = pending.count
            pending.append(chunk)
            peak = max(peak, pending.count)
            var start = pending.startIndex
            // 先前保留的半行已经检查过，只在新读入的数据中找换行。
            var searchStart = start + bufferedBytes
            while let end = pending[searchStart...].firstIndex(of: 10) {
                guard values.count < count, end > start else { throw BookError.invalid("听书索引行数损坏") }
                guard end - start <= lineByteLimit else { throw BookError.invalid("听书索引单项过大") }
                values.append(try decoder.decode(type, from: pending[start..<end]))
                start = end + 1
                searchStart = start
            }
            if start > pending.startIndex { pending.removeSubrange(pending.startIndex..<start) }
            guard pending.count <= lineByteLimit else { throw BookError.invalid("听书索引单项过大") }
        }
        guard pending.isEmpty, values.count == count else { throw BookError.invalid("听书索引不完整") }
        return (values, peak)
    }
}

/// 只缓冲一个 JSON 值的兼容读取器；跳过旧索引句子时不复制其字节。
private final class JSONValueStream {
    private let handle: FileHandle
    private let limit: Int
    private var buffer = Data()
    private var position = 0
    private var total = 0
    private(set) var peakBufferedBytes = 0
    init(_ file: URL, limit: Int) throws {
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= limit else { throw BookError.invalid("书籍索引文件超过容量限制") }
        handle = try FileHandle(forReadingFrom: file); self.limit = limit
    }
    deinit { try? handle.close() }

    private func peek() throws -> UInt8? {
        if position >= buffer.count {
            try Task.checkCancellation()
            buffer = try handle.read(upToCount: 64 * 1024) ?? Data(); position = 0; total += buffer.count
            guard total <= limit else { throw BookError.invalid("书籍索引文件超过容量限制") }
            peakBufferedBytes = max(peakBufferedBytes, buffer.count)
        }
        return position < buffer.count ? buffer[position] : nil
    }
    private func pop() throws -> UInt8? { let byte = try peek(); if byte != nil { position += 1 }; return byte }
    private func whitespace() throws { while let byte = try peek(), [9, 10, 13, 32].contains(byte) { position += 1 } }
    private func expect(_ byte: UInt8) throws { try whitespace(); guard try pop() == byte else { throw BookError.invalid("旧版听书索引格式损坏") } }

    func object(_ visit: (String) throws -> Void) throws {
        try expect(123)
        var keys: Set<String> = []
        try whitespace()
        if try peek() == 125 { _ = try pop(); return }
        while true {
            let key = try decodeValue(String.self, limit: 4096)
            guard keys.insert(key).inserted else { throw BookError.invalid("旧版听书索引键重复") }
            try expect(58); try visit(key); try whitespace()
            let end = try pop()
            if end == 125 { break }
            guard end == 44 else { throw BookError.invalid("旧版听书索引格式损坏") }
        }
        try whitespace()
        guard try peek() == nil else { throw BookError.invalid("旧版听书索引包含多余内容") }
    }

    func array(limit: Int, _ visit: () throws -> Void) throws {
        try expect(91); try whitespace()
        if try peek() == 93 { _ = try pop(); return }
        var count = 0
        while true {
            try Task.checkCancellation()
            guard count < limit else { throw BookError.invalid("听书索引项数超出限制") }
            try visit(); count += 1; try whitespace()
            let end = try pop()
            if end == 93 { return }
            guard end == 44 else { throw BookError.invalid("旧版听书索引格式损坏") }
        }
    }

    func decodeValue<T: Decodable>(_ type: T.Type, limit: Int) throws -> T {
        try JSONDecoder().decode(type, from: value(capture: true, limit: limit))
    }
    func skipValue() throws { _ = try value(capture: false, limit: 0) }

    private func value(capture: Bool, limit: Int) throws -> Data {
        try whitespace()
        guard let first = try peek() else { throw BookError.invalid("旧版听书索引不完整") }
        var data = Data()
        var stack: [UInt8] = []
        var inString = false
        var escaped = false
        let compound = first == 123 || first == 91
        let quoted = first == 34
        var consumed = false
        while let byte = try peek() {
            if !inString && stack.isEmpty && consumed && !compound && !quoted && [9, 10, 13, 32, 44, 93, 125].contains(byte) { break }
            _ = try pop()
            if capture {
                guard data.count < limit else { throw BookError.invalid("听书索引单项过大") }
                data.append(byte); peakBufferedBytes = max(peakBufferedBytes, buffer.count + data.count)
            }
            consumed = true
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false; if quoted && stack.isEmpty { break } }
            } else if byte == 34 { inString = true }
            else if byte == 123 || byte == 91 {
                guard stack.count < 256 else { throw BookError.invalid("听书索引嵌套过深") }
                stack.append(byte == 123 ? 125 : 93)
            } else if byte == 125 || byte == 93 {
                guard stack.popLast() == byte else { throw BookError.invalid("听书索引括号损坏") }
                if compound && stack.isEmpty { break }
            }
        }
        guard consumed, !inString, stack.isEmpty else { throw BookError.invalid("旧版听书索引不完整") }
        return data
    }
}
