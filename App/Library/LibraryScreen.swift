import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO
import FreeReadingCore

enum LibraryTheme {
    static let paper = Color(red: 0.969, green: 0.961, blue: 0.937)
    static let forest = Color(red: 0.27, green: 0.39, blue: 0.33)
    static let ink = Color(red: 0.16, green: 0.18, blue: 0.16)
}

/// 与 Android 对齐的本地书架：导入进度、错误重试和后台听书入口各自保留状态。
struct LibraryScreen: View {
    @ObservedObject var store: AppStore
    @State private var importing = false
    @State private var deleting: BookRecord?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("FREE READING").font(.caption).tracking(3).foregroundStyle(.secondary)
                        Text("把书读进生活里").font(.system(.largeTitle, design: .serif)).foregroundStyle(LibraryTheme.ink)
                        Text("离线阅读，随时听书。").foregroundStyle(.secondary)
                        Label("本地 EPUB · 系统语音", systemImage: "headphones")
                            .font(.caption).foregroundStyle(LibraryTheme.forest)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(LibraryTheme.forest.opacity(0.08), in: Capsule())
                    }.padding(.top, 18)
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("我的书架").font(.system(.title2, design: .serif))
                            Text("共 \(store.books.count) 本").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { importing = true } label: { Label("导入 EPUB", systemImage: "plus") }
                            .buttonStyle(.borderedProminent).disabled(store.busy)
                    }
                    if let progress = store.importProgress { ImportProgressView(progress: progress) }
                    if store.isOpening { HStack { ProgressView(); Text("正在打开书籍…").font(.callout) } }
                    if store.books.isEmpty {
                        ContentUnavailableView {
                            Label("让第一本书住进来", systemImage: "book.closed")
                        } description: {
                            Text("从“文件”导入 EPUB，或使用系统的打开方式交给 FreeReading。")
                        } actions: {
                            Button("选择 EPUB") { importing = true }.disabled(store.busy)
                        }.padding(.vertical, 24)
                    } else {
                        LazyVStack(spacing: 14) {
                            ForEach(store.books) { book in
                                Button { store.open(book) } label: {
                                    BookLibraryRow(book: book, repository: store.repository)
                                }
                                .buttonStyle(.plain)
                                .disabled(store.busy)
                                .contextMenu {
                                    Button("打开阅读", systemImage: "book") { store.open(book) }
                                    Button("打开听书", systemImage: "headphones") { store.open(book, player: true) }
                                    Button("移除书籍", systemImage: "trash", role: .destructive) { deleting = book }
                                }
                            }
                        }
                    }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
            .background(LibraryTheme.paper)
            .navigationTitle("FreeReading")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MiniPlayer(playback: store.playback) {
                    if let id = store.playback.snapshot.bookID, let book = store.books.first(where: { $0.id == id }) {
                        store.open(book, player: true)
                    }
                }
            }
        }
        .task { await store.refresh() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "epub") ?? .data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { store.importBook(url) }
            case .failure(let error): store.errorMessage = error.localizedDescription
            }
        }
        .fullScreenCover(item: $store.route) { route in
            ReaderScreen(book: route.book, repository: store.repository, playback: store.playback, openPlayer: route.openPlayer)
                .id(route.id)
        }
        .alert("操作未完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .confirmationDialog("移除书籍及其本地进度？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let book = deleting {
                Button("移除《\(book.title)》", role: .destructive) { deleting = nil; store.remove(book) }
            }
        }
    }
}

private struct BookLibraryRow: View {
    let book: BookRecord
    let repository: BookRepository
    @State private var cover: UIImage?
    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(LibraryTheme.forest)
                if let cover { Image(uiImage: cover).resizable().scaledToFill() }
                else { Text(book.title).font(.system(.caption, design: .serif)).foregroundStyle(.white).padding(10) }
            }.frame(width: 72, height: 104).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 10) {
                Text(book.title).font(.system(.title3, design: .serif)).foregroundStyle(LibraryTheme.ink).lineLimit(2)
                Text(book.author.isEmpty ? "未知作者" : book.author).font(.caption).foregroundStyle(.secondary)
                Label("开始阅读", systemImage: "book").font(.caption).foregroundStyle(LibraryTheme.forest)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }.padding(14).background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
        .task(id: book.coverPath) {
            guard let path = book.coverPath else { return }
            let url = repository.bookDirectory(id: book.id).appendingPathComponent(path)
            cover = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 500,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) else { return nil as UIImage? }
                return UIImage(cgImage: image)
            }.value
        }
    }
}

private struct ImportProgressView: View {
    let progress: ImportProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                if let fraction = progress.fraction { Text("\(Int(fraction * 100))%").monospacedDigit() }
            }.font(.caption)
            if let fraction = progress.fraction { ProgressView(value: fraction) }
            else { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
            Text("显示当前步骤进度").font(.caption2).foregroundStyle(.secondary)
        }.padding(14).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
    }
    private var title: String {
        switch progress.stage {
        case .copying: return "复制书籍"
        case .validating: return "检查 EPUB"
        case .indexing: return "整理正文"
        case .saving: return "保存书籍"
        case .completed: return "导入完成"
        }
    }
}

private struct MiniPlayer: View {
    @ObservedObject var playback: PlaybackController
    let open: () -> Void
    var body: some View {
        if playback.snapshot.bookID != nil {
            HStack(spacing: 14) {
                Button(action: open) {
                    HStack(spacing: 12) {
                        Image(systemName: "headphones")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(playback.book?.record.title ?? "正在听书").font(.callout).lineLimit(1)
                            Text(playback.snapshot.isPreparing ? "正在准备声音…" : playback.snapshot.text)
                                .font(.caption).opacity(0.7).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.buttonStyle(.plain)
                Button(action: playback.toggle) {
                    Image(systemName: playback.snapshot.wantsPlayback ? "pause.fill" : "play.fill")
                        .frame(width: 44, height: 44)
                }.accessibilityLabel(playback.snapshot.wantsPlayback ? "暂停听书" : "继续听书")
            }.foregroundStyle(.white).padding(.horizontal, 24).padding(.vertical, 8).background(LibraryTheme.forest)
        }
    }
}
