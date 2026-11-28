import PDFKit
import SwiftUI
import FreeReadingCore

/// PDF 保留原版页面，播放游标用页码和阅读页同步。
@MainActor
struct PDFReaderScreen: View {
    let bootstrap: ReadingBookBootstrap
    let repository: BookRepository
    @ObservedObject var playback: PlaybackController
    let openPlayer: Bool
    let isRouteActive: () -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var document: PDFDocument?
    @State private var openFailed = false
    @State private var page: Int
    @State private var pageRequest: PDFPageRequest
    @State private var resumeProgress: ReadingProgress?
    @State private var deferredFollow: ReaderAudioNavigationDeferral?
    @State private var pageChangedManually = false
    @State private var preparingSpeech = false
    @State private var speechTask: Task<Void, Never>?
    @State private var speechRequestID: UUID?
    @State private var showPlayer = false
    @State private var showPagePicker = false
    @State private var pageInput = ""
    @State private var error: String?

    init(bootstrap: ReadingBookBootstrap, repository: BookRepository, playback: PlaybackController,
         openPlayer: Bool, isRouteActive: @escaping () -> Bool) {
        self.bootstrap = bootstrap
        self.repository = repository
        self.playback = playback
        self.openPlayer = openPlayer
        self.isRouteActive = isRouteActive
        let restoredPage = bootstrap.pdfPage ?? bootstrap.progress?.chapterIndex ?? 0
        let initialPage = max(0, min(bootstrap.book.record.chapterCount - 1, restoredPage))
        _page = State(initialValue: initialPage)
        _pageRequest = State(initialValue: PDFPageRequest(index: initialPage))
        _resumeProgress = State(initialValue: bootstrap.progress)
    }

    private var book: ReadingBook { bootstrap.book }
    private var hasText: Bool { book.record.sentenceCount > 0 }
    private var pageCount: Int { document?.pageCount ?? book.record.chapterCount }
    private var typedPage: Int? {
        guard let number = Int(pageInput.trimmingCharacters(in: .whitespacesAndNewlines)),
              number > 0, number <= pageCount else { return nil }
        return number - 1
    }
    private var ownsAudio: Bool {
        playback.snapshot.bookID == book.record.id && playback.book?.record.addedAt == book.record.addedAt
    }
    private var cursor: PDFPlaybackCursor {
        let audio = playback.snapshot
        return PDFPlaybackCursor(
            sentence: ownsAudio ? audio.sentenceIndex : nil,
            page: audio.chapterIndex, playing: ownsAudio && audio.isPlaying, wantsPlayback: ownsAudio && audio.wantsPlayback
        )
    }
    private let colors = ReadingColors(theme: "paper")

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    cancelSpeechLoad()
                    dismiss()
                } label: {
                    Image(systemName: "arrow.left").frame(width: 44, height: 44)
                }
                .accessibilityLabel("返回书架")
                Text(book.record.title).font(.headline).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                if hasText {
                    Button { showPlayer = true } label: {
                        Label("听书", systemImage: "headphones").padding(.horizontal, 8).frame(minHeight: 44)
                    }
                    .disabled(document == nil)
                }
            }
            .padding(.horizontal, 8)
            Divider()
            if let document {
                PDFPageView(document: document, currentPage: page, request: pageRequest, onPageChanged: pageDidChange)
                    .accessibilityIdentifier("pdf.document")
                Divider()
                HStack {
                    pageButton("chevron.left", label: "上一页", target: page - 1)
                    Spacer()
                    Button("第 \(page + 1) / \(pageCount) 页") {
                        pageInput = String(page + 1)
                        showPagePicker = true
                    }
                    .monospacedDigit().frame(minHeight: 44)
                    .accessibilityLabel("第 \(page + 1) 页，共 \(pageCount) 页，跳转页码")
                    Spacer()
                    pageButton("chevron.right", label: "下一页", target: page + 1)
                }
                .padding(.horizontal, 12)
            } else if openFailed {
                ContentUnavailableView("PDF 无法打开", systemImage: "doc", description: Text("请从书架重新导入。"))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(colors.paper.ignoresSafeArea())
        .foregroundStyle(colors.ink)
        .tint(colors.accent)
        .task {
            guard document == nil, !openFailed else { return }
            guard let url = try? repository.pdfURL(bookID: book.record.id),
                  let opened = PDFDocument(url: url), !opened.isLocked, opened.pageCount > 0,
                  opened.pageCount == book.record.chapterCount else {
                openFailed = true; return
            }
            document = opened
            applyAudio()
            if openPlayer && hasText { showPlayer = true }
        }
        .onChange(of: cursor) { _, _ in applyAudio() }
        .fullScreenCover(isPresented: $showPlayer, onDismiss: { cancelSpeechLoad(); applyAudio() }) {
            ListeningScreen(book: book, repository: repository, readingReady: document != nil, playback: playback,
                isLoadingSpeech: preparingSpeech, onMainAction: primaryPlayback,
                onFromReading: { startFromPage(resume: false) },
                onPreviousChapter: { playback.previousChapter() }, onNextChapter: { playback.nextChapter() },
                onLocate: locateAudio, onStop: endListening)
                .alert("操作未完成", isPresented: errorPresented(inPlayer: true)) {
                    Button("知道了", role: .cancel) { error = nil }
                } message: { Text(error ?? "") }
        }
        .alert("跳转页码", isPresented: $showPagePicker) {
            TextField("页码", text: $pageInput).keyboardType(.numberPad)
            Button("跳转") {
                if let typedPage { selectPage(typedPage) }
            }.disabled(typedPage == nil)
            Button("取消", role: .cancel) { }
        }
        .alert("操作未完成", isPresented: errorPresented(inPlayer: false)) {
            Button("知道了", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func errorPresented(inPlayer: Bool) -> Binding<Bool> {
        Binding(get: { error != nil && showPlayer == inPlayer }, set: { if !$0 { error = nil } })
    }

    private func pageButton(_ symbol: String, label: String, target: Int) -> some View {
        Button { selectPage(target) } label: {
            Image(systemName: symbol).frame(width: 44, height: 44)
        }
        .accessibilityLabel(label)
        .disabled(!(0..<pageCount).contains(target))
    }

    private func selectPage(_ target: Int) {
        guard target != page else { return }
        go(to: target)
        recordManualPage()
    }

    private func pageDidChange(_ index: Int, request: UUID) {
        guard pageRequest.id == request, (0..<pageCount).contains(index), page != index else { return }
        page = index
        recordManualPage()
    }

    private func recordManualPage() {
        cancelSpeechLoad()
        let playbackCursor = cursor
        if playbackCursor.wantsPlayback, let sentence = playbackCursor.sentence {
            if playbackCursor.playing { deferredFollow = .readingSentence(sentence) }
            else if deferredFollow == nil { deferredFollow = .waitingForPlayback }
        } else {
            pageChangedManually = true
            resumeProgress = nil
        }
        savePage()
    }

    private func savePage() {
        let record = book.record
        let index = page
        let updatedAt = Date()
        let save = Task { @MainActor in
            do {
                try await repository.savePDFReadingPage(bookID: record.id, index: index,
                    expectedAddedAt: record.addedAt, updatedAt: updatedAt)
            } catch {
                if isRouteActive() { self.error = error.localizedDescription }
            }
        }
        repository.registerReadingSave(bookID: record.id, expectedAddedAt: record.addedAt, task: save)
    }

    private func applyAudio() {
        let current = cursor
        if let deferral = deferredFollow, let index = current.sentence, deferral.shouldWait(
            wantsPlayback: current.wantsPlayback, isPlaying: current.playing, sentenceIndex: index
        ) { return }
        deferredFollow = nil
        guard current.wantsPlayback, speechRequestID == nil else { return }
        pageChangedManually = false
        if current.page != page {
            go(to: current.page)
            savePage()
        }
    }

    private func go(to target: Int) {
        guard (0..<pageCount).contains(target), target != page else { return }
        page = target
        pageRequest = PDFPageRequest(index: target)
    }

    private func primaryPlayback() {
        if ReaderProgressPolicy.shouldToggleExistingAudio(
            ownsAudio: ownsAudio, wantsPlayback: cursor.wantsPlayback, fromReading: pageChangedManually
        ) {
            cancelSpeechLoad()
            playback.toggle()
            applyAudio()
        } else {
            startFromPage(resume: !pageChangedManually)
        }
    }

    private func startFromPage(resume: Bool) {
        guard hasText else { return }
        cancelSpeechLoad()
        let request = UUID()
        let requestedPage = page
        let saved = resume ? resumeProgress : nil
        let record = book.record
        speechRequestID = request
        preparingSpeech = true
        speechTask = Task { @MainActor in
            defer {
                if speechRequestID == request { speechRequestID = nil; preparingSpeech = false; speechTask = nil }
            }
            do {
                let indexed = try await repository.loadSpeechBook(id: record.id)
                guard !Task.isCancelled, isRouteActive(), speechRequestID == request, page == requestedPage,
                      indexed.record.addedAt == record.addedAt else { return }
                let target: Int
                let offset: Double
                if let saved, saved.elementID != nil, saved.chapterIndex == requestedPage,
                   indexed.sentences.indices.contains(saved.sentenceIndex),
                   indexed.sentences[saved.sentenceIndex].chapterIndex == requestedPage {
                    target = saved.sentenceIndex
                    offset = saved.audioOffset
                } else if let index = indexed.sentences.firstIndex(where: { $0.chapterIndex >= requestedPage }) {
                    target = index
                    offset = 0
                } else {
                    error = "此页之后没有可朗读文字，请跳到有文字的页。"; return
                }
                speechRequestID = nil
                preparingSpeech = false
                speechTask = nil
                deferredFollow = nil
                pageChangedManually = false
                resumeProgress = nil
                playback.start(book: indexed, sentenceIndex: target, offset: offset)
                applyAudio()
            } catch is CancellationError { }
            catch { if speechRequestID == request { self.error = error.localizedDescription } }
        }
    }

    private func cancelSpeechLoad() {
        speechTask?.cancel()
        speechTask = nil
        speechRequestID = nil
        preparingSpeech = false
    }

    private func locateAudio() {
        guard ownsAudio else { return }
        cancelSpeechLoad()
        deferredFollow = nil
        pageChangedManually = false
        if playback.snapshot.chapterIndex != page {
            go(to: playback.snapshot.chapterIndex)
            savePage()
        }
    }

    private func endListening() {
        guard ownsAudio else { return }
        cancelSpeechLoad()
        let snapshot = playback.snapshot
        resumeProgress = ReadingProgress(bookID: book.record.id, chapterIndex: snapshot.chapterIndex,
            elementID: "pdf-page-\(snapshot.chapterIndex)", sentenceIndex: snapshot.sentenceIndex, audioOffset: snapshot.position)
        playback.stop()
        showPlayer = false
    }
}

private struct PDFPlaybackCursor: Equatable {
    let sentence: Int?
    let page: Int
    let playing: Bool
    let wantsPlayback: Bool
}

private struct PDFPageRequest {
    let id = UUID()
    let index: Int
}

/// PDFKit 负责分页和缩放。只对新定位命令调用 go，避免手动滑动被视图刷新拉回。
@MainActor
private struct PDFPageView: UIViewRepresentable {
    let document: PDFDocument
    let currentPage: Int
    let request: PDFPageRequest
    let onPageChanged: (Int, UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFReaderView {
        let view = PDFReaderView()
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.usePageViewController(true, withViewOptions: nil)
        view.backgroundColor = UIColor.systemBackground
        view.autoScales = true
        view.document = document
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged),
            name: .PDFViewPageChanged, object: view)
        return view
    }

    func updateUIView(_ view: PDFReaderView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onPageChanged = onPageChanged
        guard coordinator.lastRequest != request.id else { return }
        let index = coordinator.lastRequest == nil ? currentPage : request.index
        guard let target = document.page(at: index) else { return }
        coordinator.lastRequest = request.id
        view.requestPage(target)
    }

    static func dismantleUIView(_ view: PDFReaderView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewPageChanged, object: view)
        coordinator.onPageChanged = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        var lastRequest: UUID?
        var onPageChanged: ((Int, UUID) -> Void)?

        @objc func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFReaderView, let request = lastRequest else { return }
            // 读取这一轮布局后的最终页，忽略定位过程中 PDFKit 临时就绪的页面通知。
            Task { @MainActor [weak self, weak view] in
                if let view, !view.hasPendingPage, let document = view.document, let page = view.currentPage {
                    self?.onPageChanged?(document.index(for: page), request)
                }
            }
        }
    }
}

/// 让首次页码恢复等到 PDFView 已有可用尺寸，随后只处理新的跳页请求。
@MainActor
private final class PDFReaderView: PDFView {
    private var pendingPage: PDFPage?
    var hasPendingPage: Bool { pendingPage != nil }

    func requestPage(_ page: PDFPage) {
        pendingPage = page
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, let page = pendingPage else { return }
        pendingPage = nil
        go(to: page)
    }
}
