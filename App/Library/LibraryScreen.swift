import SwiftUI
import UIKit
import UniformTypeIdentifiers
import FreeReadingCore

/// 沿用 Android 的纸色书架、文案和卡片层级，文件选择与确认仍使用 iOS 系统组件。
@MainActor
struct LibraryScreen: View {
    @ObservedObject var store: AppStore
    @State private var importing = false
    @State private var deleting: BookRecord?
    @State private var voiceSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LibraryHeader { voiceSettings = true }
                    LibraryIntroduction()
                    shelfHeading
                    if let progress = store.importProgress {
                        ImportProgressView(progress: progress, cancel: store.cancelImport)
                    }
                    if store.importState.canRetry { importRetry }
                    if store.isOpening {
                        HStack(spacing: 10) {
                            ProgressView().tint(LibraryTheme.forest)
                            Text("正在铺开书页…").font(.subheadline).foregroundStyle(LibraryTheme.muted)
                        }
                        .accessibilityIdentifier("library.opening")
                    }
                    if store.books.isEmpty {
                        EmptyLibrary(isImporting: store.importState.isImporting, disabled: store.isRemoving) {
                            importing = true
                        }
                    } else {
                        LazyVStack(spacing: 18) {
                            ForEach(store.books) { book in
                                BookLibraryRow(
                                    book: book, repository: store.repository,
                                    open: { store.open(book) },
                                    openListening: { store.open(book, player: true) },
                                    remove: { deleting = book }
                                )
                                .disabled(store.busy)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
            .background(LibraryTheme.paper.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MiniPlayer(playback: store.playback) {
                    if let id = store.playback.snapshot.bookID,
                       let book = store.books.first(where: { $0.id == id }) {
                        store.open(book, player: true)
                    }
                }
            }
        }
        .tint(LibraryTheme.forest)
        .preferredColorScheme(.light)
        .task { await store.refresh(); store.consumeShareInbox() }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.epub, .pdf],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls): if let url = urls.first { store.importBook(url) }
            case .failure(let error): store.errorMessage = error.localizedDescription
            }
        }
        .fullScreenCover(item: $store.route, onDismiss: store.consumeShareInbox) { route in
            Group {
                if route.bootstrap.book.record.format == .pdf {
                    PDFReaderScreen(bootstrap: route.bootstrap, repository: store.repository,
                        playback: store.playback, openPlayer: route.openPlayer,
                        isRouteActive: { store.route?.sessionID == route.sessionID })
                } else {
                    ReaderScreen(bootstrap: route.bootstrap, repository: store.repository,
                        playback: store.playback, openPlayer: route.openPlayer)
                }
            }
            .id(route.id)
        }
        .alert("语音设置", isPresented: $voiceSettings) {
            Button("关闭", role: .cancel) {}
        } message: {
            Text("FreeReading 使用 iOS 系统声音。请在系统辅助功能的语音设置中下载所需声音，在听书页选择并验证音色。离线使用前，请完成下载并断网试听。")
        }
        .alert("操作未完成", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("关闭", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .confirmationDialog(
            "移除书籍",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            if let book = deleting {
                Button("移除《\(book.title)》", role: .destructive) {
                    deleting = nil; store.remove(book)
                }
                Button("取消", role: .cancel) { deleting = nil }
            }
        } message: {
            if let book = deleting {
                Text("移除《\(book.title)》及它的阅读进度和语音缓存？原始导入文件仍保留在原位置。")
            }
        }
    }

    private var shelfHeading: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(LibraryTheme.outline.opacity(0.6)).frame(height: 1)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    shelfCount
                    Spacer(minLength: 8)
                    if !store.books.isEmpty { shelfImportButton }
                }
                VStack(alignment: .leading, spacing: 14) {
                    shelfCount
                    if !store.books.isEmpty { shelfImportButton }
                }
            }
            .padding(.top, 22)
        }
    }

    private var shelfCount: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("我的书架")
                .font(.system(.title2, design: .serif).weight(.medium))
                .foregroundStyle(LibraryTheme.ink)
            Text("\(store.books.count) 本藏书")
                .font(.caption).foregroundStyle(LibraryTheme.muted)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var shelfImportButton: some View {
        Button { importing = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 18))
                Text(store.importState.isImporting ? "重新选择文件" : "导入书籍")
                    .font(.caption.weight(.medium))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(LibraryTheme.forest, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(store.isRemoving)
        .accessibilityIdentifier("library.import")
    }

    /// 重试与换源沿用已有会话；宽度不足时纵排，避免大字号挤出书架。
    private var importRetry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("导入未完成", systemImage: "exclamationmark.circle")
                .font(.subheadline.weight(.medium)).foregroundStyle(LibraryTheme.ink)
            Text(store.importState.error ?? "请重试或重新选择文件。")
                .font(.subheadline).foregroundStyle(LibraryTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { retryButtons }
                VStack(alignment: .leading, spacing: 4) { retryButtons }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LibraryTheme.surfaceVariant, in: RoundedRectangle(cornerRadius: 12))

    }

    @ViewBuilder private var retryButtons: some View {
        Button("重试导入", action: store.retryImport)
            .buttonStyle(.borderedProminent).accessibilityIdentifier("library.retryImport")
        Button("重新选择") { importing = true }
            .frame(minHeight: 44).accessibilityIdentifier("library.replaceImport")
        Button("取消", action: store.cancelImport)
            .frame(minHeight: 44).accessibilityIdentifier("library.cancelFailedImport")
    }
}

/// 自绘顶栏与 Android 保持相同的书本标志、衬线标题和语音入口。
private struct LibraryHeader: View {
    let voiceSettings: () -> Void
    @ScaledMetric(relativeTo: .title2) private var titleSize = 22.0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "book.fill")
                .font(.system(size: 27, weight: .regular))
                .foregroundStyle(LibraryTheme.forest)
                .accessibilityHidden(true)
            Text("FreeReading")
                .font(.system(size: titleSize, weight: .medium, design: .serif))
                .foregroundStyle(LibraryTheme.ink)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: voiceSettings) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 22))
                    .foregroundStyle(LibraryTheme.forest)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("语音设置")
            .accessibilityIdentifier("library.voiceSettings")
        }
        .padding(.top, 16)
    }
}

private struct LibraryIntroduction: View {
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize = 32.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("READ AT YOUR OWN PACE")
                .font(.system(size: 10)).tracking(2)
                .foregroundStyle(LibraryTheme.muted)
            Text("让阅读，慢下来。")
                .font(.system(size: heroSize, weight: .medium, design: .serif))
                .lineSpacing(7)
                .foregroundStyle(LibraryTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("library.hero")
            Text("每一本书，都是一段自己的时间。")
                .font(.subheadline).lineSpacing(3)
                .foregroundStyle(LibraryTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: "headphones").font(.system(size: 14))
                Text("离线阅读 · 系统听书").font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(LibraryTheme.forest)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(LibraryTheme.badge, in: Capsule())
            .padding(.top, 6)
        }
        .padding(.top, 16).padding(.bottom, 8)
    }
}

private struct EmptyLibrary: View {
    let isImporting: Bool
    let disabled: Bool
    let openImporter: () -> Void
    @ScaledMetric(relativeTo: .headline) private var titleSize = 19.0

    var body: some View {
        VStack(spacing: 16) {
            EmptyLibraryArtwork()
                .frame(width: 210, height: 138)
                .accessibilityHidden(true)
            Text("下一段旅程，从一本书开始")
                .font(.system(size: titleSize, design: .serif))
                .foregroundStyle(LibraryTheme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("导入本地 EPUB 或 PDF，随时阅读和听书。")
                .font(.subheadline).lineSpacing(3)
                .foregroundStyle(LibraryTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: openImporter) {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 20))
                    Text(isImporting ? "重新选择文件" : "导入书籍")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .frame(minHeight: 50)
                .background(LibraryTheme.forest, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain).disabled(disabled)
            .padding(.top, 8)
            .accessibilityIdentifier("library.emptyImport")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)

    }
}

/// 与 Android 同源的书本轮廓，用矢量绘制避免引入额外位图资源。
private struct EmptyLibraryArtwork: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let oval = Path(ellipseIn: CGRect(x: w * 0.08, y: h * 0.12, width: w * 0.84, height: h * 0.82))
            context.fill(oval, with: .color(Color(freeReadingHex: 0xE5E8D9)))
            var left = Path()
            left.move(to: CGPoint(x: w * 0.17, y: h * 0.24))
            left.addQuadCurve(to: CGPoint(x: w * 0.5, y: h * 0.35), control: CGPoint(x: w * 0.35, y: h * 0.18))
            left.addLine(to: CGPoint(x: w * 0.5, y: h * 0.84))
            left.addQuadCurve(to: CGPoint(x: w * 0.17, y: h * 0.73), control: CGPoint(x: w * 0.35, y: h * 0.66))
            left.closeSubpath()
            context.fill(left, with: .color(Color(freeReadingHex: 0xFDFCF6)))
            var right = Path()
            right.move(to: CGPoint(x: w * 0.5, y: h * 0.35))
            right.addQuadCurve(to: CGPoint(x: w * 0.83, y: h * 0.24), control: CGPoint(x: w * 0.65, y: h * 0.18))
            right.addLine(to: CGPoint(x: w * 0.83, y: h * 0.73))
            right.addQuadCurve(to: CGPoint(x: w * 0.5, y: h * 0.84), control: CGPoint(x: w * 0.65, y: h * 0.66))
            right.closeSubpath()
            context.fill(right, with: .color(Color(freeReadingHex: 0xEEE9DB)))
            for index in 0..<4 {
                let y = h * (0.35 + Double(index) * 0.085)
                var lines = Path()
                lines.move(to: CGPoint(x: w * 0.23, y: y))
                lines.addLine(to: CGPoint(x: w * 0.43, y: y + h * 0.05))
                lines.move(to: CGPoint(x: w * 0.57, y: y + h * 0.05))
                lines.addLine(to: CGPoint(x: w * 0.77, y: y))
                context.stroke(lines, with: .color(Color(freeReadingHex: 0xADB7A0)), lineWidth: 2)
            }
        }
    }
}

/// 书籍内容按钮和更多菜单为同级控件，避免内嵌按钮导致点击误打开正文。
private struct BookLibraryRow: View {
    let book: BookRecord
    let repository: BookRepository
    let open: () -> Void
    let openListening: () -> Void
    let remove: () -> Void
    @ScaledMetric(relativeTo: .headline) private var titleSize = 19.0
    private var coverURL: URL? {
        book.coverPath.map { repository.bookDirectory(id: book.id).appendingPathComponent($0) }
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: 18) {
                    BookCoverView(title: book.title, url: coverURL, seed: book.id)
                        .frame(width: 72, height: 72 / 0.69)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(book.title)
                            .font(.system(size: titleSize, design: .serif)).lineSpacing(3)
                            .foregroundStyle(LibraryTheme.ink).lineLimit(2)
                        Text(book.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "佚名" : book.author)
                            .font(.caption).foregroundStyle(LibraryTheme.muted).lineLimit(1)
                        HStack(spacing: 5) {
                            Image(systemName: "book").font(.system(size: 14))
                            Text("开始阅读").font(.caption)
                        }
                        .foregroundStyle(LibraryTheme.forest)
                        .padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library.book.\(book.id)")
            Menu {
                Button("打开阅读", systemImage: "book", action: open)
                if book.format != .pdf || book.sentenceCount > 0 {
                    Button("打开听书", systemImage: "headphones", action: openListening)
                }
                Button("移除书籍", systemImage: "trash", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
                    .foregroundStyle(LibraryTheme.muted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("《\(book.title)》书籍操作")
            .accessibilityIdentifier("library.bookMenu.\(book.id)")
        }
        .padding(14)
        .background(LibraryTheme.card, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct ImportProgressView: View {
    let progress: ImportProgress
    let cancel: () -> Void
    private var stage: Int {
        switch progress.stage {
        case .copying: return 1
        case .validating: return 2
        case .indexing: return 3
        case .saving, .completed: return 4
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(LibraryTheme.ink)
                Spacer(minLength: 8)
                Button("取消", action: cancel)
                    .font(.caption).frame(minHeight: 44)
                    .accessibilityIdentifier("library.cancelImport")
            }
            HStack {
                Text("第 \(stage)/4 步")
                Spacer(minLength: 8)
                if let percent = progress.percent { Text("本阶段 \(percent)%").monospacedDigit() }
            }
            .font(.caption).foregroundStyle(LibraryTheme.muted)
            if let fraction = progress.fraction {
                ProgressView(value: fraction).tint(LibraryTheme.forest)
            } else {
                ProgressView().tint(LibraryTheme.forest)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(LibraryTheme.surfaceVariant, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("书籍导入进度")
        .accessibilityIdentifier("library.importProgress")
    }

    private var title: String {
        switch progress.stage {
        case .copying: return "复制文件"
        case .validating: return "检查书籍"
        case .indexing: return "整理正文"
        case .saving: return "保存书籍"
        case .completed: return "导入完成"
        }
    }
}

/// 与 Android 一致的深绿迷你播放器；打开入口和播放按钮独立，不改变播放器生命周期。
private struct MiniPlayer: View {
    @ObservedObject var playback: PlaybackController
    let open: () -> Void
    @StateObject private var loading = PlaybackLoadingPresentation()
    private var preparingForPlayback: Bool {
        playback.snapshot.bookID != nil && playback.snapshot.isPreparing && playback.snapshot.wantsPlayback
    }
    private var chapterTitle: String {
        guard let book = playback.book, book.chapters.indices.contains(playback.snapshot.chapterIndex) else { return "正在听" }
        let title = book.chapters[playback.snapshot.chapterIndex].title
        return title.isEmpty ? "正在听" : title
    }

    var body: some View {
        if playback.snapshot.bookID != nil {
            HStack(spacing: 0) {
                Button(action: open) {
                    HStack(spacing: 14) {
                        Image(systemName: "headphones")
                            .font(.system(size: 24))
                            .foregroundStyle(Color(freeReadingHex: 0xDDE6D4))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(playback.book?.record.title ?? "正在听书")
                                .font(.subheadline).foregroundStyle(.white).lineLimit(1)
                            Text(playback.snapshot.isPreparing ? "正在准备语音…" : chapterTitle)
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开听书页面")
                .accessibilityIdentifier("library.miniPlayer.open")
                Button(action: playback.toggle) {
                    ZStack {
                        Circle().fill(.white.opacity(0.12))
                        Image(systemName: playback.snapshot.wantsPlayback ? "pause.fill" : "play.fill")
                            .font(.system(size: 18)).foregroundStyle(.white)
                        if loading.isVisible {
                            ProgressView().tint(.white).controlSize(.mini).scaleEffect(0.6)
                                .offset(x: 13, y: -13).accessibilityHidden(true)
                        }
                    }
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playback.snapshot.wantsPlayback ? "暂停听书" : "继续听书")
                .accessibilityIdentifier("library.miniPlayer.toggle")
                .padding(.leading, 14)
            }
            .padding(.horizontal, 24).padding(.vertical, 10)
            .background(LibraryTheme.forest.ignoresSafeArea(edges: .bottom))
            .onAppear { loading.update(isPreparing: preparingForPlayback, wantsPlayback: preparingForPlayback) }
            .onChange(of: preparingForPlayback) { _, value in loading.update(isPreparing: value, wantsPlayback: value) }
            .onDisappear { loading.cancel() }
        }
    }
}
