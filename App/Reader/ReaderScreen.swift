import SwiftUI
import FreeReadingCore

private enum ReaderSheet: String, Identifiable { case contents, settings; var id: String { rawValue } }

/// 原文始终占据固定视口；顶部与底部工具叠放，听书使用独立整页呈现。
@MainActor
struct ReaderScreen: View {
    let book: ReadingBook
    let repository: BookRepository
    @ObservedObject var playback: PlaybackController
    let openPlayer: Bool
    @StateObject private var session: ReaderSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("reader.fontSize") private var fontSize = 20.0
    @AppStorage("reader.theme") private var theme = "paper"
    @AppStorage("reader.scroll") private var scroll = false
    @AppStorage("reader.followAudio") private var followAudio = true
    @State private var sheet: ReaderSheet?
    @State private var playerPresented = false
    @State private var didOpen = false

    init(bootstrap: ReadingBookBootstrap, repository: BookRepository, playback: PlaybackController, openPlayer: Bool = false) {
        book = bootstrap.book; self.repository = repository; self.playback = playback; self.openPlayer = openPlayer
        _session = StateObject(wrappedValue: ReaderSession(bootstrap: bootstrap, repository: repository, playback: playback))
    }

    init(book: SpeechBook, repository: BookRepository, playback: PlaybackController, openPlayer: Bool = false) {
        self.book = ReadingBook(book: book); self.repository = repository; self.playback = playback; self.openPlayer = openPlayer
        _session = StateObject(wrappedValue: ReaderSession(book: book, repository: repository, playback: playback))
    }

    private var colors: ReadingColors { ReadingColors(theme: theme) }
    private var appearance: ReaderAppearance { ReaderAppearance(fontSize: min(36, max(14, fontSize)), theme: theme, scroll: scroll, direction: book.readingDirection) }
    private var activeAudio: Bool { playback.snapshot.bookID == book.record.id && playback.book?.record.addedAt == book.record.addedAt }
    private var percent: Int { Int(min(1, max(0, session.readingFraction)) * 100) }
    private var followingAudio: Bool { followAudio && !session.detached }

    var body: some View {
        ZStack(alignment: .top) {
            colors.paper.ignoresSafeArea()
            if let url = session.chapterURL {
                ReaderWebView(url: url,
                    readAccessURL: repository.bookDirectory(id: book.record.id).appendingPathComponent("content", isDirectory: true),
                    appearance: appearance, navigation: session.navigation, highlight: session.highlight,
                    onAttach: session.attach, onEvent: session.handle, onDismantle: session.close)
                    .background(colors.paper)
                    .accessibilityIdentifier("reader_document")
            } else {
                ContentUnavailableView("正文无法打开", systemImage: "book.closed", description: Text("请返回书架后重新导入书籍。"))
            }
            if !session.ready {
                VStack(spacing: 16) {
                    ProgressView().tint(colors.accent)
                    Text("正在铺开书页…").font(.system(size: 19, design: .serif))
                }
                .padding(28).background(colors.paper.opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
            if session.menuVisible {
                readingToolbar.transition(.opacity)
                VStack { Spacer(); readingMenu }.transition(.opacity)
            }
            if session.selectionActive {
                VStack {
                    Spacer()
                    Button { session.startFromSelection() } label: {
                        Label("从这里听", systemImage: "headphones").font(.callout.weight(.medium))
                            .padding(.horizontal, 18).padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent).tint(colors.accent)
                    .padding(.bottom, session.menuVisible ? 74 : 10)
                    .accessibilityIdentifier("reader_listen_selection")
                }
            }
        }
        .foregroundStyle(colors.ink)
        .safeAreaInset(edge: .bottom, spacing: 0) { readingFooter }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $sheet) { target in
            switch target {
            case .contents:
                ReaderContentsSheet(book: book, currentID: session.currentContentsID, theme: theme) { entry in
                    session.chooseContents(entry); sheet = nil
                }
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
                .presentationBackground(colors.paper)
            case .settings:
                ReaderSettingsSheet(fontSize: $fontSize, theme: $theme, scroll: $scroll, followAudio: $followAudio)
                    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
                    .presentationBackground(colors.paper)
            }
        }
        .fullScreenCover(isPresented: $playerPresented, onDismiss: { session.applyAudio() }) {
            ListeningScreen(book: book, repository: repository, theme: theme, readingReady: session.ready, playback: playback,
                followAudio: $followAudio, detached: session.detached, isLoadingSpeech: session.isLoadingSpeech,
                onMainAction: session.primaryPlayback, onFromReading: session.startFromVisible,
                onPreviousChapter: { session.skipListeningChapter(forward: false) },
                onNextChapter: { session.skipListeningChapter(forward: true) },
                onResumeFollow: session.resumeFollowing, onStop: { session.endListening(); playerPresented = false })
        }
        .alert("操作未完成", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("知道了", role: .cancel) { session.error = nil }
        } message: { Text(session.error ?? "") }
        .task {
            // 返回原文仍恢复可接收事件的会话；只在首次打开时自动进入播放器。
            session.open(follow: followAudio)
            if !didOpen {
                didOpen = true
                if openPlayer { playerPresented = true }
            }
        }
        // 全屏听书只遮住原文，不结束它；真正移除 WebView 时同步登记最终保存。
        .onDisappear { session.saveNow() }
        .onChange(of: playback.snapshot.bookID) { _, _ in session.applyAudio() }
        .onChange(of: playback.snapshot.sentenceIndex) { _, _ in session.applyAudio() }
        .onChange(of: playback.snapshot.isPlaying) { _, _ in session.applyAudio() }
        .onChange(of: followAudio) { _, value in session.setFollow(value) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { session.applyAudio() } else { session.saveNow() }
        }
        .preferredColorScheme(colors.isNight ? .dark : .light)

    }

    private var readingToolbar: some View {
        HStack(spacing: 5) {
            Button {
                session.close()
                dismiss()
            } label: {
                Image(systemName: "arrow.left").font(.system(size: 21))
                    .frame(width: 40, height: 44)
            }
            .buttonStyle(.plain).accessibilityLabel("返回书架")
            .accessibilityIdentifier("reader_back")
            Text(book.record.title.isEmpty ? "阅读" : book.record.title)
                .font(.system(size: 16, weight: .medium, design: .serif))
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 16)
        }
        .padding(.horizontal, 8).frame(height: 52)
        .background(colors.paper.opacity(0.97))

    }

    private var readingMenu: some View {
        VStack(spacing: 0) {
            Rectangle().fill(colors.ink.opacity(0.09)).frame(height: 0.5)
            HStack(spacing: 0) {
                menuButton("目录", icon: "list.bullet", id: "reader_contents", enabled: session.ready) {
                    session.refreshContentsPosition(); sheet = .contents
                }
                menuButton("听书", icon: "headphones", id: "reader_listen", enabled: session.ready || activeAudio,
                    preparing: activeAudio && playback.snapshot.isPreparing, highlighted: activeAudio) { playerPresented = true }
                menuButton("设置", icon: "gearshape", id: "reader_appearance", enabled: session.ready) { sheet = .settings }
            }.padding(.horizontal, 12)
        }
        .background(colors.paper)

    }

    private func menuButton(_ title: String, icon: String, id: String, enabled: Bool,
                            preparing: Bool = false, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if preparing { ProgressView().controlSize(.small).frame(height: 21) }
                else { Image(systemName: icon).font(.system(size: 21)).frame(height: 21) }
                Text(title).font(.system(size: 12))
            }
            .frame(maxWidth: .infinity).frame(height: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .foregroundStyle((highlighted ? colors.accent : colors.ink).opacity(enabled ? 1 : 0.35))
        .accessibilityLabel(title == "目录" ? "打开目录" : title == "设置" ? "打开阅读设置" : "打开听书播放器")
        .accessibilityIdentifier(id)
    }

    private var readingFooter: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { session.menuVisible.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Text(session.chapterTitle.isEmpty ? "阅读中" : session.chapterTitle)
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text("全书 \(percent)%").monospacedDigit().fixedSize()
                }
                .font(.system(size: 10)).foregroundStyle(colors.muted)
                .frame(height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!session.ready)
            .accessibilityLabel(session.menuVisible ? "收起阅读工具" : "显示阅读工具")
            .accessibilityIdentifier("reader_controls_toggle")
            if activeAudio {
                Button {
                    if followAudio && session.detached { session.resumeFollowing() }
                    else { followAudio.toggle() }
                } label: {
                    Text(followingAudio ? "自动翻页" : "继续跟随")
                        .font(.system(size: 11)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .frame(height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(colors.accent)
                .accessibilityLabel(followingAudio ? "暂停自动翻页" : "跟随朗读自动翻页")
                .accessibilityIdentifier("reader_audio_follow")
                if !session.menuVisible {
                    Button { playerPresented = true } label: {
                        HStack(spacing: 4) {
                            if playback.snapshot.isPreparing { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "headphones").font(.system(size: 14)) }
                            Text("听书").font(.system(size: 11))
                        }.frame(height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(colors.accent)
                    .accessibilityLabel("打开听书播放器").accessibilityIdentifier("reader_listen_shortcut")
                }
            }
        }
        .padding(.horizontal, 18).frame(height: 28)
        .background(colors.paper.opacity(0.96))

    }
}

/// 打开时定位当前章节；一旦用户开始浏览，异步目录更新不再抢回滚动位置。
private struct ReaderContentsSheet: View {
    let book: ReadingBook
    let currentID: String?
    let theme: String
    let select: (ContentsEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var manuallyScrolled = false
    private var colors: ReadingColors { ReadingColors(theme: theme) }
    private var entries: [ContentsEntry] {
        book.contents.isEmpty ? book.chapters.map { ContentsEntry(id: "chapter-\($0.id)", title: $0.title, chapterIndex: $0.id) } : book.contents
    }

    var body: some View {
        VStack(spacing: 0) {
            ReaderSheetHeader(title: "目录", closeTitle: "关闭", colors: colors) { dismiss() }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(entries) { entry in
                            let current = entry.id == currentID
                            Button { select(entry) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.title).font(.system(size: 14)).lineSpacing(4)
                                        .foregroundStyle(current ? colors.accent : colors.ink)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if current { Text("当前章节").font(.system(size: 11)).foregroundStyle(colors.accent) }
                                }
                                .padding(.horizontal, 12).padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(current ? colors.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .padding(.leading, CGFloat(min(max(0, entry.depth), 6)) * 14)
                            }
                            .buttonStyle(.plain).id(entry.id)
                            .accessibilityIdentifier("reader_contents_item_\(entry.id)")
                            .accessibilityAddTraits(current ? .isSelected : [])
                        }
                    }.padding(.horizontal, 20).padding(.bottom, 20)
                }
                .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in manuallyScrolled = true })
                .onAppear { if let currentID { proxy.scrollTo(currentID, anchor: .center) } }
                .onChange(of: currentID) { _, id in if !manuallyScrolled, let id { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .background(colors.paper).foregroundStyle(colors.ink)
        .preferredColorScheme(colors.isNight ? .dark : .light)

    }
}

/// 设置采用与 Android 相同的字体比例、纸色按钮和开关分组，数据仍沿用已有阅读偏好。
private struct ReaderSettingsSheet: View {
    @Binding var fontSize: Double
    @Binding var theme: String
    @Binding var scroll: Bool
    @Binding var followAudio: Bool
    @Environment(\.dismiss) private var dismiss
    private var colors: ReadingColors { ReadingColors(theme: theme) }

    var body: some View {
        VStack(spacing: 0) {
            ReaderSheetHeader(title: "阅读设置", closeTitle: "完成", colors: colors) { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("字号").font(.system(size: 12)).foregroundStyle(colors.muted)
                    HStack {
                        fontButton("minus", label: "缩小字号", enabled: fontSize > 14) { fontSize = max(14, fontSize - 2) }
                        Spacer()
                        Text("\(Int((fontSize / 20 * 100).rounded()))%")
                            .font(.system(size: 21, design: .serif)).monospacedDigit()
                        Spacer()
                        fontButton("plus", label: "放大字号", enabled: fontSize < 36) { fontSize = min(36, fontSize + 2) }
                    }
                    Text("书页").font(.system(size: 12)).foregroundStyle(colors.muted)
                    HStack(spacing: 8) {
                        themeButton("纸色", value: "paper")
                        themeButton("明亮", value: "white")
                        themeButton("夜读", value: "night")
                    }
                    Divider().overlay(colors.ink.opacity(0.08))
                    Toggle(isOn: $scroll) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("连续滚动").font(.system(size: 14))
                            Text("关闭时左右翻页").font(.system(size: 11)).foregroundStyle(colors.muted)
                        }
                    }.tint(colors.accent).accessibilityIdentifier("reader_scroll_toggle")
                    Toggle(isOn: $followAudio) {
                        Text("听书时自动翻页").font(.system(size: 14))
                    }.tint(colors.accent).accessibilityIdentifier("reader_follow_toggle")
                }
                .frame(maxWidth: 520).padding(.horizontal, 24).padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
        }
        .background(colors.paper).foregroundStyle(colors.ink)
        .preferredColorScheme(colors.isNight ? .dark : .light)

    }

    private func fontButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 20)).frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label).accessibilityIdentifier(symbol == "minus" ? "reader_font_smaller" : "reader_font_larger")
    }

    private func themeButton(_ title: String, value: String) -> some View {
        let selected = theme == value || (value == "night" && theme == "dark")
        return Button { theme = value } label: {
            Text(title).font(.system(size: 13)).frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(selected ? colors.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).stroke(selected ? colors.accent : colors.ink.opacity(0.18), lineWidth: 1) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(selected ? colors.accent : colors.ink)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("reader_theme_\(value)")
    }
}

/// 弹层统一采用纸色标题栏，保留 iOS 的滑动关闭和安全区域行为。
private struct ReaderSheetHeader: View {
    let title: String
    let closeTitle: String
    let colors: ReadingColors
    let close: () -> Void
    var body: some View {
        HStack {
            Text(title).font(.system(size: 22, weight: .medium, design: .serif))
            Spacer()
            Button(closeTitle, action: close).font(.system(size: 14)).foregroundStyle(colors.accent)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 12)
    }
}
