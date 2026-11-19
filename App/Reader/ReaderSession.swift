import Foundation
import Combine
import UIKit
import WebKit
import FreeReadingCore

/// 协调阅读游标、用户导航意图和后台听书；首屏只依赖元数据，关闭原文不结束听书。
@MainActor
final class ReaderSession: ObservableObject {
    let book: ReadingBook
    let repository: BookRepository
    let playback: PlaybackController
    @Published private(set) var speechBook: SpeechBook?
    @Published private(set) var isLoadingSpeech = false
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
    private var pendingNavigation: ReaderNavigation?
    private var resumeProgress: ReadingProgress?
    private var fromReading = false
    private var revision = 0
    private var highlightRevision = 0
    private var startID: UUID?
    private var startTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?
    private var indexTask: Task<SpeechBook, Error>?
    private var restorationComplete = false
    private var needsLegacyRestore = false
    private var closed = false
    var followAudio = true
    private var lastFollowRequest: PlaybackFollowRequest?

    init(bootstrap: ReadingBookBootstrap, repository: BookRepository, playback: PlaybackController) {
        book = bootstrap.book; self.repository = repository; self.playback = playback
        // 已存在的播放事件不因重开页面重复消费；关闭期间的新起播已写回共享偏好。
        lastFollowRequest = playback.snapshot.followRequest
        speechBook = bootstrap.cachedSpeechBook
        restore(bootstrap.progress)
    }

    /// 兼容已有完整索引调用；新入口应先由仓库准备 ReadingBookBootstrap。
    convenience init(book: SpeechBook, repository: BookRepository, playback: PlaybackController) {
        self.init(bootstrap: ReadingBookBootstrap(book: ReadingBook(book: book), cachedSpeechBook: book), repository: repository, playback: playback)
        needsLegacyRestore = true
    }

    var chapterTitle: String { book.chapters.indices.contains(chapterIndex) ? book.chapters[chapterIndex].title : book.record.title }
    var readingFraction: Double {
        ReaderProgressPolicy.totalProgress(chapterIndex: chapterIndex, pageProgress: pageProgress,
            chapterWeights: book.chapterWeights, chapterCount: book.chapters.count)
    }
    var chapterURL: URL? {
        guard book.chapters.indices.contains(chapterIndex) else { return nil }
        return try? repository.contentURL(bookID: book.record.id, href: book.chapters[chapterIndex].href)
    }
    private var indexedBook: SpeechBook? {
        if let speechBook { return speechBook }
        // 后台播放器已有同一导入批次的索引时直接复用，控制按钮无需等待磁盘解码。
        if let playing = playback.book, playing.record.id == book.record.id, playing.record.addedAt == book.record.addedAt { return playing }
        return nil
    }
    private var canSaveVisual: Bool {
        ReaderProgressPolicy.canSaveVisual(restorationComplete: restorationComplete,
            hasCurrentAudio: ownsAudio,
            hasResumeProgress: resumeProgress != nil, fromReading: fromReading)
    }
    private var ownsAudio: Bool {
        playback.snapshot.bookID == book.record.id && playback.book?.record.addedAt == book.record.addedAt
    }

    func open(follow: Bool) {
        closed = false; followAudio = follow
        guard needsLegacyRestore else {
            restorationComplete = true; applyAudio(); return
        }
        needsLegacyRestore = false
        let token = revision
        restoreTask = Task { [weak self] in
            guard let self else { return }
            do {
                let progress = try await repository.readingProgress(bookID: book.record.id)
                guard !Task.isCancelled, !closed, revision == token else { return }
                restore(progress); restorationComplete = true; applyAudio()
            } catch let failure { if !closed { self.error = failure.localizedDescription } }
        }
    }

    private func restore(_ progress: ReadingProgress?) {
        resumeProgress = progress
        guard let progress, book.chapters.indices.contains(progress.chapterIndex) else { return }
        setChapter(progress.chapterIndex)
        pageProgress = progress.pageProgress.isFinite ? min(1, max(0, progress.pageProgress)) : 0
        issueNavigation(ReaderProgressPolicy.restorationTarget(progress: progress))
    }

    func attach(_ webView: WKWebView) { self.webView = webView }

    func handle(_ event: ReaderWebEvent) {
        guard !closed else { return }
        switch event {
        case .ready:
            ready = true
            // 等首屏真正可见后再解码长书索引；显式点播放也会复用同一任务。
            if preloadTask == nil && indexedBook == nil {
                preloadTask = Task { [weak self] in
                    guard let self else { return }
                    do { _ = try await requireSpeechBook(); if !Task.isCancelled && !closed { applyAudio() } }
                    catch { /* 阅读不依赖听书索引，起播时再显示可操作的错误。 */ }
                    preloadTask = nil
                }
            } else { applyAudio() }
        case .tap: menuVisible.toggle()
        case .manual: markManualNavigation()
        case .chapter(let delta): moveChapter(delta)
        case .anchor(let value): acceptAnchor(value)
        case .selection(let active): selectionActive = active
        case .link(let href): openLink(href)
        case .failure(let message): error = message
        case .listenSelection: startFromSelection()
        case .navigationApplied(let id):
            if pendingNavigation?.id == id { pendingNavigation = nil }
        }
    }

    private func requireSpeechBook() async throws -> SpeechBook {
        if let indexedBook { speechBook = indexedBook; return indexedBook }
        let task: Task<SpeechBook, Error>
        if let indexTask { task = indexTask }
        else {
            isLoadingSpeech = true
            let repository = repository, id = book.record.id
            task = Task { try await repository.loadSpeechBook(id: id) }
            indexTask = task
        }
        do {
            let loaded = try await task.value
            guard loaded.record.id == book.record.id, loaded.record.addedAt == book.record.addedAt else { throw CancellationError() }
            if !closed { speechBook = loaded; isLoadingSpeech = false; indexTask = nil }
            return loaded
        } catch {
            if !closed { isLoadingSpeech = false; indexTask = nil }
            throw error
        }
    }

    /// 快照中的句子是唯一同步依据；手动浏览保留高亮更新，但暂时停止自动跳页。
    func applyAudio() {
        guard !closed else { return }
        let snapshot = playback.snapshot
        guard ownsAudio, let indexedBook, indexedBook.sentences.indices.contains(snapshot.sentenceIndex) else {
            highlight = nil; return
        }
        let sentence = indexedBook.sentences[snapshot.sentenceIndex]
        let shouldNavigate = followAudio && !detached && startID == nil && !fromReading
        if shouldNavigate { revision += 1; setChapter(sentence.chapterIndex) }
        guard sentence.chapterIndex == chapterIndex else { highlight = nil; return }
        highlightRevision += 1
        highlight = ReaderHighlight(sentence: sentence.id, section: sentence.sectionID,
            start: sentence.range.start, end: sentence.range.end, navigate: shouldNavigate, revision: highlightRevision)
    }

    func markManualNavigation() {
        acknowledgeCurrentFollowRequest()
        revision += 1; restorationComplete = true
        cancelStart(); saveTask?.cancel()
        detached = true; fromReading = true; resumeProgress = nil
        navigation = nil; pendingNavigation = nil
        if var existing = highlight { existing.navigate = false; highlight = existing }
    }

    func moveChapter(_ delta: Int) {
        let target = chapterIndex + delta
        guard book.chapters.indices.contains(target) else { return }
        markManualNavigation(); setChapter(target)
        issueNavigation(.progress(delta > 0 ? 0 : 1))
        menuVisible = false; applyAudio()
    }

    func chooseContents(_ entry: ContentsEntry) {
        guard book.chapters.indices.contains(entry.chapterIndex) else { return }
        markManualNavigation(); setChapter(entry.chapterIndex)
        issueNavigation(entry.fragment.map(ReaderNavigation.Target.fragment) ?? .progress(0))
        currentContentsID = entry.id; menuVisible = false; applyAudio()
    }

    func resumeFollowing() {
        guard ownsAudio else { return }
        acknowledgeCurrentFollowRequest()
        cancelStart(); revision += 1
        detached = false; fromReading = false; resumeProgress = nil
        applyAudio()
    }

    /// 用户主动切换时立即生效，并消费此前已发布的起播事件，避免迟到回调覆盖操作。
    func setFollow(_ enabled: Bool) {
        acknowledgeCurrentFollowRequest()
        followAudio = enabled
        if enabled { resumeFollowing() } else { applyAudio() }
    }

    /// AppStorage 也会由播放器写入；同步偏好不代表用户要求跳回原文。
    func synchronizeFollowPreference(_ enabled: Bool) { followAudio = enabled; applyAudio() }

    private func acknowledgeCurrentFollowRequest() {
        guard let request = playback.snapshot.followRequest,
              request.bookID == book.record.id, request.addedAt == book.record.addedAt else { return }
        lastFollowRequest = request
    }

    /// 起播事件独立于每句状态；不取消刚发起的起播查询，也不把暂停或自然换句当作新开始。
    @discardableResult
    func followNewPlaybackStart() -> Bool {
        guard !closed, let request = playback.snapshot.followRequest,
              let enabled = request.followingPreference(bookID: book.record.id, addedAt: book.record.addedAt, after: lastFollowRequest,
                  currentPreference: UserDefaults.standard.object(forKey: PlaybackFollowRequest.preferenceKey) as? Bool ?? true) else { return false }
        lastFollowRequest = request
        followAudio = enabled
        if enabled {
            detached = false
            if startID == nil { fromReading = false; resumeProgress = nil }
        }
        applyAudio()
        return enabled
    }

    /// 同书现有音频直接切换播放意图；新起播才等待完整索引并重验用户导航代次。
    func primaryPlayback() {
        if ReaderProgressPolicy.shouldToggleExistingAudio(ownsAudio: ownsAudio,
            wantsPlayback: playback.snapshot.wantsPlayback, isPreparing: playback.snapshot.isPreparing, fromReading: fromReading) {
            cancelStart(); playback.toggle(); applyAudio(); return
        }
        guard !fromReading, let progress = resumeProgress else { startFromVisible(); return }
        cancelStart()
        let request = UUID(), token = revision
        startID = request
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let indexed = try await requireSpeechBook()
                guard !Task.isCancelled, !closed, startID == request, revision == token else { return }
                startID = nil; startTask = nil
                guard ReaderProgressPolicy.canResumeAudio(progress: progress, book: indexed) else { startFromVisible(); return }
                detached = false
                playback.start(book: indexed, sentenceIndex: progress.sentenceIndex, offset: progress.audioOffset)
                applyAudio()
            } catch { finishStartError(error, request: request) }
        }
    }

    func startFromVisible() { startFromDOM(selection: false) }
    func startFromSelection() { startFromDOM(selection: true) }

    private func startFromDOM(selection: Bool) {
        cancelStart()
        let request = UUID(), token = revision, chapter = chapterIndex
        startID = request
        startTask = Task { [weak self] in
            guard let self else { return }
            // 先捕获点击时的 DOM，防止长书索引准备期间页面变动后误从新位置起播。
            let target = await captureAnchor(selection: selection)
            do {
                let indexed = try await requireSpeechBook()
                guard !Task.isCancelled, !closed, startID == request, revision == token, chapterIndex == chapter else { return }
                startID = nil; startTask = nil
                guard let target, let index = ReaderProgressPolicy.sentenceIndex(book: indexed, chapterIndex: chapter,
                    sectionID: target.sectionID, textOffset: target.offset, startOfParagraph: !selection) else {
                    error = selection ? "未能定位选中的原文，请重新选择。" : "当前页面暂无可朗读文字，请从目录选择正文。"
                    return
                }
                fromReading = false; detached = false; resumeProgress = nil
                playback.start(book: indexed, sentenceIndex: index); applyAudio()
                if selection, let webView { _ = try? await ReaderJavaScript.evaluate("window.FreeReading.clearSelection()", in: webView) }
            } catch { finishStartError(error, request: request) }
        }
    }

    private func finishStartError(_ failure: Error, request: UUID) {
        guard !closed, startID == request else { return }
        startID = nil; startTask = nil
        if !(failure is CancellationError) { error = failure.localizedDescription }
    }

    func skipListeningChapter(forward: Bool) {
        let snapshot = playback.snapshot
        guard ownsAudio, (forward ? snapshot.canGoToNextChapter : snapshot.canGoToPreviousChapter) else { return }
        cancelStart(); revision += 1
        fromReading = false; detached = false; resumeProgress = nil
        if forward { playback.nextChapter() } else { playback.previousChapter() }
        applyAudio()
    }

    func endListening() {
        cancelStart(); saveTask?.cancel()
        let snapshot = playback.snapshot
        guard ownsAudio, let indexedBook, indexedBook.sentences.indices.contains(snapshot.sentenceIndex) else { return }
        let sentence = indexedBook.sentences[snapshot.sentenceIndex]
        let section = indexedBook.sections.first { $0.id == sentence.sectionID }
        resumeProgress = ReadingProgress(bookID: book.record.id, chapterIndex: sentence.chapterIndex,
            elementID: section?.elementID, textOffset: sentence.range.start,
            sentenceIndex: snapshot.sentenceIndex, audioOffset: snapshot.position, pageProgress: pageProgress)
        fromReading = false
        playback.stop()
        // stop 保存的音频偏移优先于后续 scroll/scene/close 产生的视觉进度。
        highlight = nil
    }

    func refreshContentsPosition() {
        let token = revision, chapter = chapterIndex
        let entries = book.contents.filter { $0.chapterIndex == chapter }
        currentContentsID = entries.first?.id ?? "chapter-\(chapter)"
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
            guard let self, !closed, revision == token, chapterIndex == chapter, let id = result as? String,
                  entries.contains(where: { $0.id == id }) else { return }
            currentContentsID = id
        }
    }

    func close() {
        guard !closed else { return }
        cancelStart(); restoreTask?.cancel(); preloadTask?.cancel(); saveTask?.cancel()
        // 在释放 WKWebView 前同步登记任务，快速重开同书必须等新鲜 DOM 游标落盘。
        scheduleFinalSave()
        closed = true; webView = nil
    }

    func saveNow() { guard !closed else { return }; scheduleFinalSave() }

    private func scheduleFinalSave() {
        guard canSaveVisual else { return }
        let repository = repository, playback = playback, id = book.record.id, addedAt = book.record.addedAt
        let fallback = pendingNavigation == nil ? anchor : nil
        let pending = pendingNavigation, chapter = chapterIndex, token = revision, web = ready ? webView : nil
        let task = Task { @MainActor [weak self] in
            var captured = fallback
            if let web {
                // 尚未确认完成的同页导航先落到 DOM，再查询；新章节尚未 ready 则走下方命令兜底。
                let navigate = pending.map { "window.FreeReading.navigate(" + ReaderWebView.Coordinator.json($0.json) + ");" } ?? ""
                if let value = try? await ReaderJavaScript.evaluate(navigate + "window.FreeReading.anchor()", in: web), let fresh = ReaderAnchor(value) { captured = fresh }
            }
            // 完整索引只参与校验与听书句子映射；仓库此 API 不等待本次 final-save gate。
            guard let indexed = try? await repository.loadSpeechBook(id: id), indexed.record.addedAt == addedAt else { return }
            guard playback.snapshot.bookID != id else { return }
            if let self, self.revision != token || !self.canSaveVisual { return }
            let progress: ReadingProgress?
            if let captured {
                progress = ReaderProgressPolicy.readingProgress(book: indexed, chapterIndex: chapter,
                    sectionID: captured.sectionID, textOffset: captured.offset, pageProgress: captured.progress)
            } else if let pending {
                progress = ReaderProgressPolicy.pendingNavigationProgress(book: indexed, chapterIndex: chapter, target: pending.target)
            } else { progress = nil }
            guard let progress else { return }
            try? await repository.saveProgress(progress, expectedAddedAt: addedAt)
        }
        repository.registerReadingSave(bookID: id, expectedAddedAt: addedAt, task: task)
    }

    private func setChapter(_ target: Int) {
        guard chapterIndex != target else { return }
        chapterIndex = target
        ready = false; anchor = nil; pageProgress = 0; selectionActive = false; highlight = nil
        navigation = nil; pendingNavigation = nil
    }

    private func issueNavigation(_ target: ReaderLocationTarget) {
        let command = ReaderNavigation(target: target)
        navigation = command; pendingNavigation = command
    }

    private func cancelStart() { startID = nil; startTask?.cancel(); startTask = nil }

    private func acceptAnchor(_ candidate: ReaderAnchor) {
        guard ready, pendingNavigation == nil else { return }
        if let indexedBook, let id = candidate.sectionID {
            guard let section = indexedBook.sections.first(where: { $0.id == id && $0.chapterIndex == chapterIndex }), candidate.offset <= section.text.utf16.count else { return }
        }
        anchor = candidate; pageProgress = candidate.progress
        guard canSaveVisual else { return }
        saveTask?.cancel()
        let token = revision, chapter = chapterIndex
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self, !closed, revision == token, canSaveVisual else { return }
            guard let indexed = try? await requireSpeechBook() else { return }
            guard !Task.isCancelled, !closed, revision == token, chapterIndex == chapter, canSaveVisual,
                  let progress = ReaderProgressPolicy.readingProgress(book: indexed, chapterIndex: chapter,
                    sectionID: candidate.sectionID, textOffset: candidate.offset, pageProgress: candidate.progress) else { return }
            try? await repository.saveProgress(progress, expectedAddedAt: book.record.addedAt)
        }
    }

    private func captureAnchor(selection: Bool) async -> ReaderAnchor? {
        guard ready, let webView else { return nil }
        let token = revision
        let value = try? await ReaderJavaScript.evaluate(selection ? "window.FreeReading.selectionAnchor()" : "window.FreeReading.anchor()", in: webView)
        guard !closed, revision == token, let value else { return nil }
        return ReaderAnchor(value)
    }

    private func openLink(_ href: String) {
        guard let base = chapterURL, let target = URL(string: href, relativeTo: base)?.absoluteURL else { return }
        if let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            // 只有用户点选的链接由系统浏览器打开，WKWebView 的网络子资源规则保持阻断。
            UIApplication.shared.open(target); return
        }
        guard target.isFileURL else { error = "此链接暂不支持打开。"; return }
        let components = URLComponents(url: target, resolvingAgainstBaseURL: true)
        guard let index = book.chapters.firstIndex(where: { chapter in
            guard let candidate = try? repository.contentURL(bookID: book.record.id, href: chapter.href) else { return false }
            return candidate.standardizedFileURL.path == target.standardizedFileURL.path
        }) else { error = "链接未指向可阅读的正文资源。"; return }
        markManualNavigation(); setChapter(index)
        issueNavigation(components?.fragment.map(ReaderNavigation.Target.fragment) ?? .progress(0))
        applyAudio()
    }
}
