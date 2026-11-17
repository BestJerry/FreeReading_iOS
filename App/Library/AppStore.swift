import Foundation
import Combine
import FreeReadingCore

struct ReadingRoute: Identifiable {
    let bootstrap: ReadingBookBootstrap
    let openPlayer: Bool
    var id: String { bootstrap.book.record.id }
}

/// 书架、导入会话和阅读导航。首屏只读取小型目录，听书索引不阻塞打开原文。
@MainActor
final class AppStore: ObservableObject {
    let repository: BookRepository
    let playback: PlaybackController
    @Published private(set) var books: [BookRecord] = []
    @Published private(set) var importState = ImportSessionState()
    @Published private(set) var isRemoving = false
    @Published private(set) var isOpening = false
    @Published var errorMessage: String?
    @Published var route: ReadingRoute?
    var busy: Bool { isRemoving || importState.isImporting }
    var importProgress: ImportProgress? { importState.progress }
    private let imports: ImportCoordinator
    private var openTask: Task<Void, Never>?
    private var navigationRevision = 0
    private let shareInbox: ShareInbox?
    private var sharedSources = Set<URL>()

    init(repository: BookRepository) {
        self.repository = repository
        playback = PlaybackController(repository: repository)
        imports = ImportCoordinator { url, progress in try await repository.importEPUB(from: url, progress: progress) }
        let group = Bundle.main.object(forInfoDictionaryKey: "FreeReadingAppGroup") as? String
        shareInbox = group.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
            .map { ShareInbox(root: $0.appendingPathComponent("EPUBInbox", isDirectory: true)) }
        imports.onStateChange = { [weak self] state in self?.importState = state }
        imports.onImported = { [weak self] book, requestID in
            guard let self else { return }
            let revision = self.navigationRevision
            Task { [weak self] in
                guard let self else { return }
                await self.refresh()
                guard self.imports.state.requestID == requestID, self.navigationRevision == revision else { return }
                do {
                    // 重复导入也必须等待上次退出的最终 DOM 保存，不能绕过快速重开保护。
                    let bootstrap = try await self.repository.prepareReadingBook(id: book.record.id)
                    guard self.imports.state.requestID == requestID, self.navigationRevision == revision else { return }
                    self.route = ReadingRoute(bootstrap: bootstrap, openPlayer: false)
                } catch {
                    if self.imports.state.requestID == requestID, self.navigationRevision == revision {
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }
        imports.onSettled = { [weak self] url, outcome in
            guard let self else { return }
            // 取消可能恰好发生在原子提交之后，书籍应出现在书架，但不强制导航。
            Task { [weak self] in await self?.refresh() }
            guard outcome != .failed, self.sharedSources.remove(url) != nil else { return }
            do { try self.shareInbox?.finish(fileURL: url) }
            catch { self.errorMessage = "分享文件清理失败：\(error.localizedDescription)" }
            // 下一份分享由返回书架或下次进入前台时处理，避免刚打开正文又跳到另一本。
        }
    }

    func refresh() async {
        do { books = try await repository.books() }
        catch { errorMessage = error.localizedDescription }
    }

    /// 允许新来源替换正在进行的导入；旧任务完全退出后才释放临时文件。
    func importBook(_ url: URL) {
        guard !isRemoving else { errorMessage = "正在移除书籍，请稍后导入。"; return }
        navigationRevision += 1
        openTask?.cancel(); isOpening = false; route = nil
        errorMessage = nil
        imports.begin(url)
    }

    func cancelImport() { navigationRevision += 1; imports.cancel() }
    func retryImport() {
        guard !isRemoving else { return }
        navigationRevision += 1; openTask?.cancel(); isOpening = false; route = nil
        imports.retry()
    }

    /// 扩展不私自唤起主应用。用户打开应用后领取分享，并复用普通导入的进度与重试。
    func consumeShareInbox() {
        guard !busy, !importState.canRetry, route == nil, sharedSources.isEmpty, let shareInbox else { return }
        do {
            let item = try shareInbox.claimNext { [weak self] _ in
                self?.errorMessage = "有一份分享文件已损坏，已隔离保存。请重新分享该 EPUB。"
            }
            if let item {
                sharedSources.insert(item.fileURL)
                importBook(item.fileURL)
            }
        } catch { errorMessage = "读取分享书籍失败：\(error.localizedDescription)" }
    }

    func open(_ record: BookRecord, player: Bool = false) {
        guard !busy else { return }
        navigationRevision += 1
        let revision = navigationRevision
        openTask?.cancel(); isOpening = true
        openTask = Task {
            defer { if revision == navigationRevision { isOpening = false } }
            do {
                let bootstrap = try await repository.prepareReadingBook(id: record.id)
                try Task.checkCancellation()
                guard revision == navigationRevision else { return }
                route = ReadingRoute(bootstrap: bootstrap, openPlayer: player)
            } catch is CancellationError { }
            catch { if revision == navigationRevision { errorMessage = error.localizedDescription } }
        }
    }

    /// 删除属于新的导航意图；旧任务不能再打开已移除的正文。
    func remove(_ record: BookRecord) {
        guard !busy else { return }
        isRemoving = true; navigationRevision += 1
        openTask?.cancel(); isOpening = false
        if route?.id == record.id { route = nil }
        if playback.snapshot.bookID == record.id { playback.stop() }
        Task {
            defer { isRemoving = false }
            do {
                try await repository.removeBook(id: record.id)
                playback.removeCachedAudio(bookID: record.id)
                await refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
