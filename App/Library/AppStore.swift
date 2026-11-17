import Foundation
import Combine
import FreeReadingCore

struct ReadingRoute: Identifiable {
    let book: SpeechBook
    let openPlayer: Bool
    var id: String { book.record.id }
}

/// 书架状态与导航；导入由独立 actor 执行，过期打开任务不能覆盖较新的书籍选择。
@MainActor
final class AppStore: ObservableObject {
    let repository: BookRepository
    let playback: PlaybackController
    @Published private(set) var books: [BookRecord] = []
    @Published private(set) var busy = false
    @Published private(set) var isOpening = false
    @Published private(set) var importProgress: ImportProgress?
    @Published var errorMessage: String?
    @Published var route: ReadingRoute?
    private var openTask: Task<Void, Never>?
    private var navigationRevision = 0
    private var importRevision = 0

    init(repository: BookRepository) {
        self.repository = repository
        playback = PlaybackController(repository: repository)
    }

    func refresh() async {
        do { books = try await repository.books() }
        catch { errorMessage = error.localizedDescription }
    }

    /// 保持临时文件访问权限直至复制完成；同一时刻仅受理一次导入。
    func importBook(_ url: URL) {
        guard !busy else { errorMessage = "正在处理书籍，请稍后再导入。"; return }
        busy = true
        navigationRevision += 1
        openTask?.cancel()
        isOpening = false
        route = nil
        importRevision += 1
        let revision = importRevision
        importProgress = ImportProgress(stage: .copying)
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() }; busy = false; importProgress = nil }
            do {
                let book = try await repository.importEPUB(from: url) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.busy, self.importRevision == revision else { return }
                        self.importProgress = progress
                    }
                }
                await refresh()
                navigationRevision += 1
                openTask?.cancel()
                isOpening = false
                route = ReadingRoute(book: book, openPlayer: false)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func open(_ record: BookRecord, player: Bool = false) {
        guard !busy else { return }
        navigationRevision += 1
        let revision = navigationRevision
        openTask?.cancel()
        isOpening = true
        openTask = Task {
            defer { if revision == navigationRevision { isOpening = false } }
            do {
                let book = try await repository.loadBook(id: record.id)
                try Task.checkCancellation()
                guard revision == navigationRevision else { return }
                route = ReadingRoute(book: book, openPlayer: player)
            } catch is CancellationError { }
            catch { if revision == navigationRevision { errorMessage = error.localizedDescription } }
        }
    }

    /// 先结束本书听书，再删除书库记录；存储层拒绝已移除书籍的迟到进度。
    func remove(_ record: BookRecord) {
        guard !busy else { return }
        busy = true
        // 删除属于新的导航意图，旧书籍加载完成后不得再打开已经移除的正文。
        navigationRevision += 1
        openTask?.cancel()
        isOpening = false
        if route?.book.record.id == record.id { route = nil }
        if playback.snapshot.bookID == record.id { playback.stop() }
        Task {
            defer { busy = false }
            do {
                try await repository.removeBook(id: record.id)
                playback.removeCachedAudio(bookID: record.id)
                await refresh()
            }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
