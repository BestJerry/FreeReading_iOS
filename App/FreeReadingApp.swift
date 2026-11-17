import SwiftUI
import FreeReadingCore

/// 应用只持有一个书库和播放控制器，关闭阅读页不会销毁后台听书。
@main
struct FreeReadingApp: App {
    @StateObject private var bootstrap = AppBootstrap()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if let store = bootstrap.store {
                    LibraryScreen(store: store)
                } else {
                    ContentUnavailableView {
                        Label("书库暂不可用", systemImage: "books.vertical")
                    } description: {
                        Text(bootstrap.error ?? "正在准备本地书库…")
                    } actions: {
                        Button("重试", action: bootstrap.prepare)
                    }
                }
            }
            .tint(LibraryTheme.forest)
            .task { bootstrap.prepare() }
            .onOpenURL { bootstrap.open($0) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { bootstrap.store?.consumeShareInbox() }
            }
        }
    }
}

/// 文件系统初始化失败时展示可重试错误，外部打开在书库就绪后继续受理。
@MainActor
final class AppBootstrap: ObservableObject {
    @Published private(set) var store: AppStore?
    @Published private(set) var error: String?
    private var pendingURL: URL?

    func prepare() {
        guard store == nil else { return }
        do {
            let repository = try BookRepository()
            let store = AppStore(repository: repository)
            self.store = store
            error = nil
            if let url = pendingURL { pendingURL = nil; store.importBook(url) }
        } catch { self.error = error.localizedDescription }
    }

    func open(_ url: URL) {
        guard let store else { pendingURL = url; prepare(); return }
        store.importBook(url)
    }
}
