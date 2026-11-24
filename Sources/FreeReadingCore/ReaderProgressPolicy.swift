import Foundation

/// 导航意图与 DOM 的当前位置分开保存；页面还没完成加载时也能持久化用户刚选的目标。
public enum ReaderLocationTarget: Equatable, Sendable {
    case progress(Double), section(Int, Int), fragment(String)
}

/// 手动翻页后延迟定位，等到新的朗读句真正开始播放。
public enum ReaderAudioNavigationDeferral: Equatable {
    case readingSentence(Int)
    case waitingForPlayback

    public func shouldWait(wantsPlayback: Bool, isPlaying: Bool, sentenceIndex: Int) -> Bool {
        wantsPlayback && (!isPlaying || self == .readingSentence(sentenceIndex))
    }
}

/// 阅读器与存储共用的纯规则；正文游标、音频游标和视觉分页比例不能相互替代。
public enum ReaderProgressPolicy {
    private static let fragmentPrefix = "fr-fragment:"
    /// 朗读中按播放意图暂停；暂停后浏览过原文时，从新的阅读位置起播。
    public static func shouldToggleExistingAudio(ownsAudio: Bool, wantsPlayback: Bool, fromReading: Bool) -> Bool {
        ownsAudio && (wantsPlayback || !fromReading)
    }
    /// 按各章正文长度加权，与 Android 的全书位置进度采用同一原则：短扉页不占一整章的权重。
    /// 权重只描述正文规模，章内仍使用排版后的视觉比例，因此它不是精确的逐字位置。
    public static func totalProgress(chapterIndex: Int, pageProgress: Double, chapterWeights: [Double], chapterCount: Int) -> Double {
        guard chapterCount > 0 else { return 0 }
        guard chapterIndex >= 0 else { return 0 }
        guard chapterIndex < chapterCount else { return 1 }
        let fraction = pageProgress.isFinite ? min(1, max(0, pageProgress)) : 0
        let weights = (0..<chapterCount).map { index -> Double in
            guard chapterWeights.indices.contains(index), chapterWeights[index].isFinite else { return 0 }
            return max(0, chapterWeights[index])
        }
        // 先归一化，避免极大书籍的权重累加溢出。
        guard let scale = weights.max(), scale > 0 else {
            return (Double(chapterIndex) + fraction) / Double(chapterCount)
        }
        let normalized = weights.map { $0 / scale }
        let total = normalized.reduce(0, +)
        let before = normalized.prefix(chapterIndex).reduce(0, +)
        return min(1, max(0, (before + normalized[chapterIndex] * fraction) / total))
    }

    /// 暂停／结束听书后保留句内音频偏移；只有明确手动阅读才让视觉游标取得保存权。
    public static func canSaveVisual(restorationComplete: Bool, hasCurrentAudio: Bool, hasResumeProgress: Bool, fromReading: Bool) -> Bool {
        restorationComplete && !hasCurrentAudio && (!hasResumeProgress || fromReading)
    }

    /// 导入时注入的稳定段落编号可直接用于首屏恢复，不必为了找它解码完整听书索引。
    public static func sectionID(elementID: String?) -> Int? {
        guard let elementID, elementID.hasPrefix("fr-section-"),
              let value = Int(elementID.dropFirst("fr-section-".count)), value >= 0 else { return nil }
        return value
    }

    public static func restorationTarget(progress: ReadingProgress) -> ReaderLocationTarget {
        if let id = sectionID(elementID: progress.elementID) { return .section(id, max(0, progress.textOffset)) }
        if let elementID = progress.elementID, elementID.hasPrefix(fragmentPrefix) {
            return .fragment(String(elementID.dropFirst(fragmentPrefix.count)))
        }
        return .progress(progress.pageProgress.isFinite ? min(1, max(0, progress.pageProgress)) : 0)
    }

    /// 未得到目标页面的 DOM 时保留导航命令本身，不能退回刚离开的旧章节或旧段落。
    public static func pendingNavigationProgress(book: SpeechBook, chapterIndex: Int, target: ReaderLocationTarget) -> ReadingProgress? {
        switch target {
        case .section(let id, let offset):
            return readingProgress(book: book, chapterIndex: chapterIndex, sectionID: id, textOffset: offset, pageProgress: 0)
        case .progress(let value):
            return readingProgress(book: book, chapterIndex: chapterIndex, sectionID: nil, textOffset: 0, pageProgress: value)
        case .fragment(let value):
            guard !value.isEmpty, value.utf8.count <= 8192,
                  var progress = readingProgress(book: book, chapterIndex: chapterIndex, sectionID: nil, textOffset: 0, pageProgress: 0) else { return nil }
            progress.elementID = fragmentPrefix + value
            return progress
        }
    }

    /// 只有视觉片段而尚无句子映射时，应先查询可见 DOM，不能误从该章第一句恢复音频。
    public static func canResumeAudio(progress: ReadingProgress, book: SpeechBook) -> Bool {
        guard progress.bookID == book.record.id, book.sentences.indices.contains(progress.sentenceIndex),
              book.sentences[progress.sentenceIndex].chapterIndex == progress.chapterIndex else { return false }
        if case .fragment = restorationTarget(progress: progress) { return false }
        return true
    }

    public static func sentenceIndex(book: SpeechBook, chapterIndex: Int, sectionID: Int?, textOffset: Int, startOfParagraph: Bool) -> Int? {
        guard let sectionID, let section = book.sections.first(where: { $0.id == sectionID && $0.chapterIndex == chapterIndex }) else { return nil }
        let offset = min(max(0, textOffset), section.text.utf16.count)
        if startOfParagraph { return book.sentences.firstIndex { $0.sectionID == sectionID } }
        return book.sentences.firstIndex {
            $0.chapterIndex == chapterIndex && (($0.sectionID == sectionID && $0.range.end > offset) || $0.sectionID > sectionID)
        } ?? book.sentences.lastIndex { $0.chapterIndex == chapterIndex && $0.sectionID == sectionID }
    }

    /// 只有在保存／听书需要时才用完整索引校验 DOM；无正文的图片页仍能保存视觉位置。
    public static func readingProgress(book: SpeechBook, chapterIndex: Int, sectionID: Int?, textOffset: Int, pageProgress: Double) -> ReadingProgress? {
        guard book.chapters.indices.contains(chapterIndex) else { return nil }
        let section = sectionID.flatMap { id in book.sections.first { $0.id == id && $0.chapterIndex == chapterIndex } }
        guard sectionID == nil || section != nil else { return nil }
        let offset = min(max(0, textOffset), section?.text.utf16.count ?? 0)
        let sentence = sentenceIndex(book: book, chapterIndex: chapterIndex, sectionID: sectionID, textOffset: offset, startOfParagraph: false)
            ?? book.sentences.firstIndex { $0.chapterIndex >= chapterIndex }
            ?? book.sentences.indices.last ?? 0
        let fraction = pageProgress.isFinite ? min(1, max(0, pageProgress)) : 0
        return ReadingProgress(bookID: book.record.id, chapterIndex: chapterIndex, elementID: section?.elementID,
                               textOffset: offset, sentenceIndex: sentence, audioOffset: 0, pageProgress: fraction)
    }
}
