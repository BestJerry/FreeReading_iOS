import Foundation

/// 句子索引与实际句内媒体秒数；倍速不改变这条时间轴。
public struct SentencePosition: Equatable, Sendable {
    public var index: Int
    public var offset: Double
    public init(index: Int, offset: Double) { self.index = index; self.offset = offset }
}

/// 文本章节边界与累计权重，构建 O(n)，查章和章节进度均为 O(1)。
public struct PlaybackTimeline: Sendable {
    private let starts: [Int]
    private let ends: [Int]
    private let weights: [Double]

    public init(book: SpeechBook) {
        var starts = [Int](repeating: 0, count: book.sentences.count)
        var ends = starts
        var weights: [Double] = [0]
        weights.reserveCapacity(book.sentences.count + 1)
        var start = 0
        for index in book.sentences.indices {
            if index > 0 && book.sentences[index].chapterIndex != book.sentences[index - 1].chapterIndex {
                for member in start..<index { ends[member] = index }
                start = index
            }
            starts[index] = start
            weights.append(weights.last! + Double(max(1, book.text(at: index).unicodeScalars.count)))
        }
        if start < ends.count { for member in start..<ends.count { ends[member] = ends.count } }
        self.starts = starts; self.ends = ends; self.weights = weights
    }

    public func previousChapter(at index: Int) -> Int? {
        guard starts.indices.contains(index), starts[index] > 0 else { return nil }
        return starts[starts[index] - 1]
    }

    public func nextChapter(at index: Int) -> Int? {
        guard ends.indices.contains(index), ends[index] < ends.count else { return nil }
        return ends[index]
    }

    /// 当前位置按文字权重展开；仅当前句需要真实时长，未生成的后续音频不参与估算。
    public func fraction(at index: Int, offset: Double, duration: Double) -> Double {
        guard starts.indices.contains(index) else { return 0 }
        let start = starts[index], end = ends[index]
        let partial = duration.isFinite && duration > 0 && offset.isFinite ? min(1, max(0, offset / duration)) : 0
        let completed = weights[index] - weights[start]
        let current = weights[index + 1] - weights[index]
        return min(1, max(0, (completed + current * partial) / (weights[end] - weights[start])))
    }

    /// 正负跳转均跨真实句长；尚无时长的句子通过调用方按需合成，绝不按字数推测秒数。
    public static func seek(sentenceCount: Int, from start: SentencePosition, by delta: Double,
                            duration: (Int) async throws -> Double) async throws -> SentencePosition {
        guard sentenceCount > 0 else { return SentencePosition(index: 0, offset: 0) }
        var index = min(max(0, start.index), sentenceCount - 1)
        var length = try await checkedDuration(index, duration)
        var position = min(length, max(0, start.offset.isFinite ? start.offset : 0))
        var remaining = min(3_600, max(-3_600, delta.isFinite ? delta : 0))
        if remaining >= 0 {
            while remaining > 0 {
                try Task.checkCancellation()
                let available = length - position
                if remaining < available || index == sentenceCount - 1 {
                    position = min(length, position + remaining)
                    break
                }
                remaining -= available
                index += 1
                length = try await checkedDuration(index, duration)
                position = 0
            }
        } else {
            remaining = -remaining
            while remaining > 0 {
                try Task.checkCancellation()
                if remaining <= position || index == 0 {
                    position = max(0, position - remaining)
                    break
                }
                remaining -= position
                index -= 1
                length = try await checkedDuration(index, duration)
                position = length
            }
        }
        return SentencePosition(index: index, offset: position)
    }

    private static func checkedDuration(_ index: Int, _ read: (Int) async throws -> Double) async throws -> Double {
        try Task.checkCancellation()
        let value = try await read(index)
        guard value.isFinite, value > 0 else { throw TimelineError.invalidDuration }
        return value
    }

    public enum TimelineError: Error { case invalidDuration }
}
