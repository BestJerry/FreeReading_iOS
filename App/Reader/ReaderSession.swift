import Foundation
import Combine
import WebKit
import FreeReadingCore

/// 协调阅读游标、用户导航意图和后台听书；页面关闭后不接管音频生命周期。
@MainActor
final class ReaderSession: ObservableObject {
    let book: SpeechBook
    let repository: BookRepository
    let playback: PlaybackController
    @Published var chapterIndex = 0
    @Published var navigation: ReaderNavigation?
    @Published var highlight: ReaderHighlight?
    @Published var menuVisible = false
    @Published var detached = false
    @Published var ready = false
    @Published var selectionActive = false
    @Published var pageProgress = 0.0
    @Published var currentContentsID: String?
    @Published var error: String?
    weak var webView: WKWebView?
    private var anchor: ReaderAnchor?
    private var resumeProgress: ReadingProgress?
    private var fromReading = false
    private var revision = 0
    private var highlightRevision = 0
    private var startID: UUID?
    private var startTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var restorationComplete = false
    var followAudio = true

    init(book: SpeechBook, repository: BookRepository, playback: PlaybackController) {
        self.book = book; self.repository = repository; self.playback = playback
    }

    var chapterTitle: String { book.chapters.indices.contains(chapterIndex) ? book.chapters[chapterIndex].title : book.record.title }
    var readingFraction: Double {
        guard !book.chapters.isEmpty else { return 0 }
        return min(1, max(0, (Double(chapterIndex) + pageProgress) / Double(book.chapters.count)))
    }
    var chapterURL: URL? {
        guard book.chapters.indices.contains(chapterIndex) else { return nil }
        return try? repository.contentURL(bookID: book.record.id, href: book.chapters[chapterIndex].href)
    }

    /// 恢复位置只在用户还未导航时应用；活动听书可按长期跟随偏好优先定位。
    func open(follow: Bool) {
        followAudio = follow
        let token = revision
        restoreTask?.cancel()
        restoreTask = Task { [weak self] in
            guard let self else { return }
            do {
                let progress = try await repository.readingProgress(bookID: book.record.id)
                guard !Task.isCancelled, self.revision == token else { return }
                self.resumeProgress = progress
                if let progress, book.chapters.indices.contains(progress.chapterIndex) {
                    self.setChapter(progress.chapterIndex)
                    self.pageProgress = progress.pageProgress.isFinite ? min(1, max(0, progress.pageProgress)) : 0
                    if let id = progress.elementID,
                       let section = book.sections.first(where: { $0.elementID == id && $0.chapterIndex == progress.chapterIndex }) {
                        self.navigation = ReaderNavigation(target: .section(section.id, min(max(0, progress.textOffset), section.text.utf16.count)))
                    } else {
                        self.navigation = ReaderNavigation(target: .progress(self.pageProgress))
                    }
                }
                self.restorationComplete = true
                self.applyAudio()
            } catch { self.error = error.localizedDescription }
        }
    }

    func attach(_ webView: WKWebView) { self.webView = webView }

    func handle(_ event: ReaderWebEvent) {
        switch event {
        case .ready: ready = true
        case .tap: menuVisible.toggle()
        case .manual: markManualNavigation()
        case .chapter(let delta): moveChapter(delta)
        case .anchor(let value): acceptAnchor(value)
        case .selection(let active): selectionActive = active
        case .link(let href): openLink(href)
        case .failure(let message): error = message
        case .listenSelection: startFromSelection()
        }
    }

    /// 快照中的句子是唯一同步依据；手动浏览保留高亮更新，但暂时停止自动跳页。
    func applyAudio() {
        let snapshot = playback.snapshot
        guard snapshot.bookID == book.record.id, book.sentences.indices.contains(snapshot.sentenceIndex) else {
            highlight = nil; return
        }
        let sentence = book.sentences[snapshot.sentenceIndex]
        let shouldNavigate = followAudio && !detached && startID == nil && !fromReading
        if shouldNavigate {
            revision += 1
            setChapter(sentence.chapterIndex)
        }
        guard sentence.chapterIndex == chapterIndex else { highlight = nil; return }
        highlightRevision += 1
        highlight = ReaderHighlight(sentence: sentence.id, section: sentence.sectionID,
                                    start: sentence.range.start, end: sentence.range.end,
                                    navigate: shouldNavigate, revision: highlightRevision)
    }

    func markManualNavigation() {
        revision += 1
        restorationComplete = true
        cancelStart()
        detached = true
        fromReading = true
        resumeProgress = nil
        if var existing = highlight { existing.navigate = false; highlight = existing }
    }

    func moveChapter(_ delta: Int) {
        let target = chapterIndex + delta
        guard book.chapters.indices.contains(target) else { return }
        markManualNavigation()
        setChapter(target)
        navigation = ReaderNavigation(target: .progress(delta > 0 ? 0 : 1))
        menuVisible = false
        applyAudio()
    }

    func chooseContents(_ entry: ContentsEntry) {
        guard book.chapters.indices.contains(entry.chapterIndex) else { return }
        markManualNavigation()
        setChapter(entry.chapterIndex)
        navigation = ReaderNavigation(target: entry.fragment.map(ReaderNavigation.Target.fragment) ?? .progress(0))
        currentContentsID = entry.id
        menuVisible = false
        applyAudio()
    }

    func resumeFollowing() {
        cancelStart(); revision += 1
        detached = false; fromReading = false; resumeProgress = nil
        applyAudio()
    }

    func setFollow(_ enabled: Bool) {
        followAudio = enabled
        if enabled { resumeFollowing() } else { applyAudio() }
    }

    /// 已有本书音频时操作其播放意图，主动导航后则从当前可见原段落重新起播。
    func primaryPlayback() {
        if playback.snapshot.bookID == book.record.id && !fromReading {
            cancelStart()
            playback.toggle()
            if playback.snapshot.isPlaying { applyAudio() }
        } else if !fromReading, let progress = resumeProgress, book.sentences.indices.contains(progress.sentenceIndex) {
            cancelStart()
            detached = false
            playback.start(book: book, sentenceIndex: progress.sentenceIndex, offset: progress.audioOffset)
            applyAudio()
        } else { startFromVisible() }
    }

    func startFromVisible() { startFromDOM(selection: false) }
    func startFromSelection() { startFromDOM(selection: true) }

    /// 查询前登记请求，完成后重验导航代次，防止旧页面的异步结果拉回新章节。
    private func startFromDOM(selection: Bool) {
        cancelStart()
        let request = UUID(), token = revision, chapter = chapterIndex
        startID = request
        startTask = Task { [weak self] in
            guard let self else { return }
            let target = await self.captureAnchor(selection: selection)
            guard !Task.isCancelled, self.startID == request, self.revision == token, self.chapterIndex == chapter else { return }
            self.startID = nil; self.startTask = nil
            guard let target,
                  let index = self.sentenceIndex(for: target, startOfParagraph: !selection) else {
                self.error = selection ? "未能定位选中的原文，请重新选择。" : "当前页面暂无可朗读文字，请从目录选择正文。"
                return
            }
            self.fromReading = false; self.detached = false; self.resumeProgress = nil
            self.playback.start(book: self.book, sentenceIndex: index)
            self.applyAudio()
            if selection, let webView = self.webView { _ = try? await ReaderJavaScript.evaluate("window.FreeReading.clearSelection()", in: webView) }
        }
    }

    func skipListeningChapter(forward: Bool) {
        let snapshot = playback.snapshot
        guard snapshot.bookID == book.record.id,
              (forward ? snapshot.canGoToNextChapter : snapshot.canGoToPreviousChapter) else { return }
        cancelStart(); revision += 1
        fromReading = false; detached = false; resumeProgress = nil
        if forward { playback.nextChapter() } else { playback.previousChapter() }
        applyAudio()
    }

    func endListening() {
        cancelStart()
        let snapshot = playback.snapshot
        if snapshot.bookID == book.record.id, book.sentences.indices.contains(snapshot.sentenceIndex) {
            let sentence = book.sentences[snapshot.sentenceIndex]
            resumeProgress = ReadingProgress(bookID: book.record.id, chapterIndex: sentence.chapterIndex,
                sentenceIndex: sentence.id, audioOffset: snapshot.position)
            fromReading = false
            playback.stop()
        }
    }

    /// 目录显示依据当前原文页，单资源多锚点交给 DOM 顺序判定。
    func refreshContentsPosition() {
        let token = revision, chapter = chapterIndex
        let entries = book.contents.filter { $0.chapterIndex == chapter }
        currentContentsID = entries.first?.id
        guard ready, let webView else { return }
        let values: [[String: Any]] = entries.map { entry in
            var value: [String: Any] = ["id": entry.id, "depth": entry.depth]
            if let fragment = entry.fragment { value["fragment"] = fragment }
            return value
        }
        let script = "window.FreeReading.contents(" + ReaderWebView.Coordinator.json(values) + ")"
        Task { [weak self, weak webView] in
            guard let webView else { return }
            let result = try? await ReaderJavaScript.evaluate(script, in: webView)
            guard let self, self.revision == token, self.chapterIndex == chapter, let id = result as? String,
                  entries.contains(where: { $0.id == id }) else { return }
            self.currentContentsID = id
        }
    }

    func close() {
        cancelStart()
        restoreTask?.cancel()
        saveTask?.cancel()
        saveNow()
        webView = nil
    }

    func saveNow() {
        guard restorationComplete, playback.snapshot.bookID != book.record.id, let progress = makeProgress() else { return }
        let repository = repository, addedAt = book.record.addedAt
        // 离页保存独立完成；仓库会拒绝已移除书籍和晚到的旧进度。
        Task { try? await repository.saveProgress(progress, expectedAddedAt: addedAt) }
    }

    private func setChapter(_ target: Int) {
        guard chapterIndex != target else { return }
        chapterIndex = target
        ready = false; anchor = nil; pageProgress = 0; selectionActive = false; highlight = nil
    }

    private func cancelStart() {
        startID = nil; startTask?.cancel(); startTask = nil
    }

    private func acceptAnchor(_ candidate: ReaderAnchor) {
        if let id = candidate.sectionID {
            guard book.sections.indices.contains(id), book.sections[id].chapterIndex == chapterIndex,
                  candidate.offset <= book.sections[id].text.utf16.count else { return }
        }
        anchor = candidate
        pageProgress = candidate.progress
        guard restorationComplete, playback.snapshot.bookID != book.record.id else { return }
        saveTask?.cancel()
        let token = revision
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self, self.revision == token,
                  self.playback.snapshot.bookID != self.book.record.id, let progress = self.makeProgress() else { return }
            try? await self.repository.saveProgress(progress, expectedAddedAt: self.book.record.addedAt)
        }
    }

    private func makeProgress() -> ReadingProgress? {
        guard let anchor else { return nil }
        let index = sentenceIndex(for: anchor, startOfParagraph: false) ??
            book.sentences.firstIndex { $0.chapterIndex >= chapterIndex } ?? 0
        let elementID = anchor.sectionID.flatMap { book.sections.indices.contains($0) ? book.sections[$0].elementID : nil }
        return ReadingProgress(bookID: book.record.id, chapterIndex: chapterIndex, elementID: elementID,
            textOffset: anchor.offset, sentenceIndex: index, audioOffset: 0, pageProgress: anchor.progress)
    }

    private func sentenceIndex(for anchor: ReaderAnchor, startOfParagraph: Bool) -> Int? {
        guard let id = anchor.sectionID, book.sections.indices.contains(id), book.sections[id].chapterIndex == chapterIndex else { return nil }
        if startOfParagraph { return book.sentences.firstIndex { $0.sectionID == id } }
        return book.sentences.firstIndex { $0.chapterIndex == chapterIndex && (($0.sectionID == id && $0.range.end > anchor.offset) || $0.sectionID > id) }
    }

    private func captureAnchor(selection: Bool) async -> ReaderAnchor? {
        guard ready, let webView else { return nil }
        let token = revision
        let value = try? await ReaderJavaScript.evaluate(selection ? "window.FreeReading.selectionAnchor()" : "window.FreeReading.anchor()", in: webView)
        guard revision == token, let value, let result = ReaderAnchor(value) else { return nil }
        return result
    }

    private func openLink(_ href: String) {
        guard let base = chapterURL, let target = URL(string: href, relativeTo: base)?.absoluteURL,
              target.isFileURL else { error = "当前阅读仅支持书内链接。"; return }
        let components = URLComponents(url: target, resolvingAgainstBaseURL: true)
        guard let index = book.chapters.firstIndex(where: { chapter in
            guard let candidate = try? repository.contentURL(bookID: book.record.id, href: chapter.href) else { return false }
            return candidate.standardizedFileURL.path == target.standardizedFileURL.path
        }) else { error = "链接未指向可阅读的正文资源。"; return }
        markManualNavigation()
        setChapter(index)
        navigation = ReaderNavigation(target: components?.fragment.map(ReaderNavigation.Target.fragment) ?? .progress(0))
        applyAudio()
    }
}
