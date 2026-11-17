import SwiftUI
import FreeReadingCore

private enum ReaderSheet: String, Identifiable { case contents, settings, player; var id: String { rawValue } }

/// 以正文为主的阅读页面；菜单叠放，听书控制由独立弹层承载。
@MainActor
struct ReaderScreen: View {
    let book: SpeechBook
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

    init(book: SpeechBook, repository: BookRepository, playback: PlaybackController, openPlayer: Bool = false) {
        self.book = book; self.repository = repository; self.playback = playback; self.openPlayer = openPlayer
        _session = StateObject(wrappedValue: ReaderSession(book: book, repository: repository, playback: playback))
    }

    private var appearance: ReaderAppearance { ReaderAppearance(fontSize: min(36, max(14, fontSize)), theme: theme, scroll: scroll) }
    private var paper: Color { theme == "night" ? Color(red: 0.094, green: 0.137, blue: 0.118) : theme == "white" ? .white : ReaderPalette.paper }
    private var ink: Color { theme == "night" ? Color(red: 0.80, green: 0.84, blue: 0.80) : ReaderPalette.ink }
    private var activeAudio: Bool { playback.snapshot.bookID == book.record.id }

    var body: some View {
        ZStack(alignment: .top) {
            paper.ignoresSafeArea()
            if let url = session.chapterURL {
                ReaderWebView(url: url,
                    readAccessURL: repository.bookDirectory(id: book.record.id).appendingPathComponent("content", isDirectory: true),
                    appearance: appearance, navigation: session.navigation, highlight: session.highlight,
                    onAttach: session.attach, onEvent: session.handle)
                    .background(paper)
            } else {
                ContentUnavailableView("正文无法打开", systemImage: "book.closed", description: Text("请返回书架后重新导入书籍。"))
            }
            if !session.ready {
                ProgressView("正在铺开书页").padding(18).background(paper.opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
            if session.menuVisible { readingMenu.transition(.opacity.combined(with: .move(edge: .top))) }
            if session.selectionActive {
                VStack {
                    Spacer()
                    Button { session.startFromSelection() } label: {
                        Label("从这里听", systemImage: "headphones").font(.callout.weight(.medium))
                            .padding(.horizontal, 18).padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent).tint(ReaderPalette.forest)
                    .padding(.bottom, 10)
                }
            }
        }
        .foregroundStyle(ink)
        .safeAreaInset(edge: .bottom, spacing: 0) { readingFooter }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $sheet) { target in
            switch target {
            case .contents:
                ReaderContentsSheet(book: book, currentID: session.currentContentsID) { entry in
                    session.chooseContents(entry); sheet = nil
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            case .settings:
                ReaderSettingsSheet(fontSize: $fontSize, theme: $theme, scroll: $scroll, followAudio: $followAudio)
                    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            case .player:
                ListeningScreen(book: book, repository: repository, playback: playback,
                    followAudio: $followAudio, detached: session.detached,
                    onMainAction: session.primaryPlayback, onFromReading: session.startFromVisible,
                    onPreviousChapter: { session.skipListeningChapter(forward: false) },
                    onNextChapter: { session.skipListeningChapter(forward: true) },
                    onResumeFollow: session.resumeFollowing, onStop: { session.endListening(); sheet = nil })
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("知道了", role: .cancel) { session.error = nil }
        } message: { Text(session.error ?? "") }
        .task {
            session.open(follow: followAudio)
            if openPlayer { sheet = .player }
        }
        .onDisappear { session.close() }
        .onChange(of: playback.snapshot.bookID) { _, _ in session.applyAudio() }
        .onChange(of: playback.snapshot.sentenceIndex) { _, _ in session.applyAudio() }
        .onChange(of: playback.snapshot.isPlaying) { _, _ in session.applyAudio() }
        .onChange(of: followAudio) { _, value in session.setFollow(value) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { session.applyAudio() } else { session.saveNow() }
        }
        .preferredColorScheme(theme == "night" ? .dark : .light)
    }

    private var readingMenu: some View {
        HStack(spacing: 18) {
            Button { dismiss() } label: { Image(systemName: "chevron.left").font(.title3.weight(.medium)).frame(width: 32, height: 44) }
                .accessibilityLabel("返回书架")
            VStack(alignment: .leading, spacing: 3) {
                Text("FREE READING").font(.system(size: 9, weight: .medium, design: .rounded)).tracking(2.8).opacity(0.55)
                Text(book.record.title).font(.headline).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { sheet = .settings } label: { Text("Aa").font(.system(size: 25, design: .serif)).frame(width: 36, height: 44) }
                .accessibilityLabel("阅读设置")
            Button {
                session.refreshContentsPosition()
                sheet = .contents
            } label: { Image(systemName: "list.bullet").font(.title3).frame(width: 36, height: 44) }
                .accessibilityLabel("目录")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(paper.opacity(0.97))
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
    }

    private var readingFooter: some View {
        HStack(spacing: 12) {
            if activeAudio {
                Button {
                    if followAudio && session.detached { session.resumeFollowing() }
                    else { followAudio.toggle() }
                } label: {
                    Label(followAudio ? (session.detached ? "继续跟随" : "自动翻页") : "开启自动翻页",
                          systemImage: followAudio && !session.detached ? "location.fill" : "location")
                        .font(.caption).lineLimit(1)
                }.buttonStyle(.plain)
            } else {
                Button { withAnimation(.easeOut(duration: 0.15)) { session.menuVisible.toggle() } } label: {
                    Text(session.chapterTitle).font(.caption2).lineLimit(1)
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 4)
            Text(session.readingFraction, format: .percent.precision(.fractionLength(0))).font(.caption2).monospacedDigit().opacity(0.6)
            Button { sheet = .player } label: {
                Label("听书", systemImage: "headphones").font(.caption.weight(.medium))
            }.buttonStyle(.plain).accessibilityLabel("打开听书页面")
        }
        .padding(.horizontal, 20).frame(minHeight: 44)
        .background(paper)
        .overlay(alignment: .top) { Divider().opacity(0.3) }
    }
}

enum ReaderPalette {
    static let paper = Color(red: 0.969, green: 0.961, blue: 0.937)
    static let ink = Color(red: 0.157, green: 0.235, blue: 0.196)
    static let forest = Color(red: 0.271, green: 0.392, blue: 0.329)
}

/// 打开时滚到当前目录项；用户开始浏览后，不用异步定位结果抢回滚动位置。
private struct ReaderContentsSheet: View {
    let book: SpeechBook
    let currentID: String?
    let select: (ContentsEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var manuallyScrolled = false
    private var entries: [ContentsEntry] {
        book.contents.isEmpty ? book.chapters.map { ContentsEntry(id: "chapter-\($0.id)", title: $0.title, chapterIndex: $0.id) } : book.contents
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(entries) { entry in
                    Button { select(entry) } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.title).foregroundStyle(.primary).lineLimit(3)
                                if entry.id == currentID { Text("当前章节").font(.caption).foregroundStyle(ReaderPalette.forest) }
                            }.padding(.leading, CGFloat(min(entry.depth, 6)) * 14)
                            Spacer(minLength: 4)
                            if entry.id == currentID { Image(systemName: "checkmark").foregroundStyle(ReaderPalette.forest) }
                        }.padding(.vertical, 5)
                    }.id(entry.id)
                }
                .listStyle(.plain)
                .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in manuallyScrolled = true })
                .onAppear { if let currentID { proxy.scrollTo(currentID, anchor: .center) } }
                .onChange(of: currentID) { _, id in if !manuallyScrolled, let id { proxy.scrollTo(id, anchor: .center) } }
            }
            .navigationTitle("目录").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

private struct ReaderSettingsSheet: View {
    @Binding var fontSize: Double
    @Binding var theme: String
    @Binding var scroll: Bool
    @Binding var followAudio: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("字号") {
                    HStack { Text("小"); Slider(value: $fontSize, in: 14...36, step: 1); Text("大") }
                    Text("\(Int(fontSize)) pt").monospacedDigit().foregroundStyle(.secondary)
                }
                Section("纸色") {
                    Picker("纸色", selection: $theme) { Text("纸色").tag("paper"); Text("纯白").tag("white"); Text("夜读").tag("night") }
                        .pickerStyle(.segmented)
                }
                Section("阅读方式") {
                    Toggle("连续滚动", isOn: $scroll)
                    Toggle("听书时自动翻页", isOn: $followAudio)
                }
            }.navigationTitle("阅读设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
