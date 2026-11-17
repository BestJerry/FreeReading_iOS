import Foundation

/// EPUB 的页面前进方向；旧书未保存此字段时沿用从左向右的阅读方式。
public enum ReadingDirection: String, Codable, Sendable { case leftToRight, rightToLeft }

/// 书架元数据；书籍 ID 使用原 EPUB 的 SHA-256，原文件移走后仍可独立阅读。
public struct BookRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var author: String
    public var language: String
    public var addedAt: Date
    public var coverPath: String?
    public var chapterCount: Int
    public var sentenceCount: Int
    public var readingDirection: ReadingDirection?

    public init(id: String, title: String, author: String = "", language: String = "zh-CN", addedAt: Date = Date(), coverPath: String? = nil, chapterCount: Int = 0, sentenceCount: Int = 0, readingDirection: ReadingDirection? = nil) {
        self.id = id; self.title = title; self.author = author; self.language = language
        self.addedAt = addedAt; self.coverPath = coverPath
        self.chapterCount = chapterCount; self.sentenceCount = sentenceCount
        self.readingDirection = readingDirection
    }
}

/// 首屏所需的小型目录，与完整听书索引独立保存，长书也能先展示原文。
public struct ReadingBook: Codable, Equatable, Sendable {
    public var record: BookRecord
    public var chapters: [BookChapter]
    public var contents: [ContentsEntry]
    public var chapterWeights: [Double]
    public var readingDirection: ReadingDirection { record.readingDirection ?? .leftToRight }
    public init(record: BookRecord, chapters: [BookChapter], contents: [ContentsEntry], chapterWeights: [Double]) {
        self.record = record; self.chapters = chapters; self.contents = contents; self.chapterWeights = chapterWeights
    }
    public init(book: SpeechBook) {
        var weights = Array(repeating: 0.0, count: book.chapters.count)
        for section in book.sections where weights.indices.contains(section.chapterIndex) {
            weights[section.chapterIndex] += Double(section.text.utf16.count)
        }
        self.init(record: book.record, chapters: book.chapters, contents: book.contents, chapterWeights: weights)
    }
}

/// 同一次开书得到的目录和阅读位置；内存中已有听书索引时复用它。
public struct ReadingBookBootstrap: Equatable, Sendable {
    public var book: ReadingBook
    public var progress: ReadingProgress?
    public var cachedSpeechBook: SpeechBook?
    public init(book: ReadingBook, progress: ReadingProgress? = nil, cachedSpeechBook: SpeechBook? = nil) {
        self.book = book; self.progress = progress; self.cachedSpeechBook = cachedSpeechBook
    }
}

/// EPUB spine 的一个正文资源；章节控制与章节进度共用该边界。
public struct BookChapter: Codable, Identifiable, Equatable, Sendable {
    public var id: Int
    public var href: String
    public var title: String
    public init(id: Int, href: String, title: String) { self.id = id; self.href = href; self.title = title }
}

/// 原文文本块，句子共享正文，避免长篇小说中反复复制完整段落。
public struct BookSection: Codable, Identifiable, Equatable, Sendable {
    public var id: Int
    public var chapterIndex: Int
    public var elementID: String
    public var text: String
    public init(id: Int, chapterIndex: Int, elementID: String, text: String) {
        self.id = id; self.chapterIndex = chapterIndex; self.elementID = elementID; self.text = text
    }
}

/// 与 DOM Range 对应的 UTF-16 偏移，结束位置不包含在范围内。
public struct TextRange: Codable, Equatable, Sendable {
    public var start: Int
    public var end: Int
    public init(start: Int, end: Int) { self.start = start; self.end = end }
}

/// 全书句子索引与共享原段落范围；不依赖字号、分页或播放速度。
public struct SpeechSentence: Codable, Identifiable, Equatable, Sendable {
    public var id: Int
    public var sectionID: Int
    public var range: TextRange
    public var chapterIndex: Int
    public init(id: Int, sectionID: Int, range: TextRange, chapterIndex: Int) {
        self.id = id; self.sectionID = sectionID; self.range = range; self.chapterIndex = chapterIndex
    }
}

/// 展平后的目录项，保留嵌套层级和同资源内的锚点。
public struct ContentsEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var chapterIndex: Int
    public var fragment: String?
    public var depth: Int
    public init(id: String, title: String, chapterIndex: Int, fragment: String? = nil, depth: Int = 0) {
        self.id = id; self.title = title; self.chapterIndex = chapterIndex; self.fragment = fragment; self.depth = depth
    }
}

/// 书籍正文与句子索引；所有索引由导入器验证后持久化。
public struct SpeechBook: Codable, Equatable, Sendable {
    public var record: BookRecord
    public var chapters: [BookChapter]
    public var sections: [BookSection]
    public var sentences: [SpeechSentence]
    public var contents: [ContentsEntry]
    public init(record: BookRecord, chapters: [BookChapter], sections: [BookSection], sentences: [SpeechSentence], contents: [ContentsEntry]) {
        self.record = record; self.chapters = chapters; self.sections = sections; self.sentences = sentences; self.contents = contents
    }

    public func text(at index: Int) -> String {
        guard sentences.indices.contains(index) else { return "" }
        let sentence = sentences[index]
        guard sections.indices.contains(sentence.sectionID) else { return "" }
        let text = sections[sentence.sectionID].text as NSString
        guard sentence.range.start >= 0, sentence.range.end <= text.length, sentence.range.end > sentence.range.start else { return "" }
        return text.substring(with: NSRange(location: sentence.range.start, length: sentence.range.end - sentence.range.start))
    }
}

/// 视觉阅读位置与句内媒体时间分别保存，避免手动翻阅覆盖正在听的音频游标。
public struct ReadingProgress: Codable, Equatable, Sendable {
    public var bookID: String
    public var chapterIndex: Int
    public var elementID: String?
    public var textOffset: Int
    public var sentenceIndex: Int
    public var audioOffset: Double
    public var pageProgress: Double
    public var updatedAt: Date
    public init(bookID: String, chapterIndex: Int = 0, elementID: String? = nil, textOffset: Int = 0, sentenceIndex: Int = 0, audioOffset: Double = 0, pageProgress: Double = 0, updatedAt: Date = Date()) {
        self.bookID = bookID; self.chapterIndex = chapterIndex; self.elementID = elementID; self.textOffset = textOffset
        self.sentenceIndex = sentenceIndex; self.audioOffset = audioOffset; self.pageProgress = pageProgress; self.updatedAt = updatedAt
    }
}

/// 导入阶段独立报告进度；只有 completed 表示整次导入提交成功。
public struct ImportProgress: Equatable, Sendable {
    public enum Stage: String, Sendable { case copying, validating, indexing, saving, completed }
    public var stage: Stage
    public var completed: Int64
    public var total: Int64?
    public var fraction: Double? { total.flatMap { $0 > 0 ? min(1, max(0, Double(completed) / Double($0))) : nil } }
    /// 使用宽整数乘除，既不受浮点舍入影响，也不会因超大文件的字节数乘 100 溢出。
    public var percent: Int? {
        guard let total, total > 0 else { return nil }
        let current = UInt64(min(total, max(0, completed)))
        return Int(UInt64(total).dividingFullWidth(current.multipliedFullWidth(by: 100)).quotient)
    }
    public init(stage: Stage, completed: Int64 = 0, total: Int64? = nil) { self.stage = stage; self.completed = completed; self.total = total }
}
