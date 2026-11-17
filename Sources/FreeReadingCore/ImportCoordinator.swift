import Foundation

/// 导入会话的可观察状态；失败保留来源，允许在原文件权限仍有效时重试。
public struct ImportSessionState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, importing, failed, cancelled, completed }
    public var requestID: UUID?
    public var phase: Phase = .idle
    public var sourceURL: URL?
    public var progress: ImportProgress?
    public var error: String?
    public var isImporting: Bool { phase == .importing }
    public var canRetry: Bool { phase == .failed && sourceURL != nil }
    public init() {}
}

/// UI 与导入工作分离：新来源取代旧请求，迟到的进度、结果和错误均不能覆盖新会话。
@MainActor
public final class ImportCoordinator {
    public typealias Importer = @Sendable (URL, @escaping @Sendable (ImportProgress) -> Void) async throws -> SpeechBook
    public enum Outcome: Equatable, Sendable { case imported, failed, cancelled }
    public private(set) var state = ImportSessionState()
    public var onStateChange: ((ImportSessionState) -> Void)?
    public var onImported: ((SpeechBook, UUID) -> Void)?
    /// 工作已退出后才通知来源清理，避免取消时删除仍在复制的临时文件。
    public var onSettled: ((URL, Outcome) -> Void)?
    private let importer: Importer
    private var task: Task<Void, Never>?
    private var source: SourceAccess?

    public init(importer: @escaping Importer) { self.importer = importer }

    /// 权限在创建任务前取得；会话失败时继续持有，替换或取消后由旧任务退出释放。
    public func begin(_ url: URL) {
        if state.isImporting, state.sourceURL == url { return }
        let discardedFailure = state.canRetry && state.sourceURL != url ? state.sourceURL : nil
        task?.cancel()
        let lease = SourceAccess(url)
        source = lease
        let id = UUID()
        state = ImportSessionState()
        state.requestID = id; state.sourceURL = url; state.phase = .importing
        state.progress = ImportProgress(stage: .copying)
        onStateChange?(state)
        if let discardedFailure { onSettled?(discardedFailure, .cancelled) }
        let operation = importer
        task = Task { [weak self, lease] in
            do {
                let book = try await operation(lease.url) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.state.requestID == id, self.state.isImporting else { return }
                        self.state.progress = progress
                        self.onStateChange?(self.state)
                    }
                }
                guard !Task.isCancelled else {
                    self?.onSettled?(lease.url, .cancelled); return
                }
                guard let self, self.state.requestID == id else { return }
                self.state.phase = .completed; self.state.progress = nil
                self.source = nil; self.task = nil
                self.onStateChange?(self.state)
                self.onImported?(book, id)
                self.onSettled?(lease.url, .imported)
            } catch {
                guard let self else { return }
                if Task.isCancelled || error is CancellationError {
                    if self.state.requestID == id, self.state.isImporting {
                        self.state.phase = .cancelled; self.state.progress = nil
                        self.source = nil; self.task = nil
                        self.onStateChange?(self.state)
                    }
                    self.onSettled?(lease.url, .cancelled)
                    return
                }
                guard self.state.requestID == id else { return }
                self.state.phase = .failed; self.state.progress = nil
                self.state.error = error.localizedDescription
                self.task = nil
                self.onStateChange?(self.state)
                self.onSettled?(lease.url, .failed)
            }
        }
    }

    public func retry() { if state.canRetry, let url = state.sourceURL { begin(url) } }

    public func cancel() {
        guard state.isImporting || state.canRetry else { return }
        let failedURL = state.canRetry ? state.sourceURL : nil
        task?.cancel(); task = nil; source = nil
        state.requestID = UUID(); state.phase = .cancelled
        state.progress = nil; state.error = nil; state.sourceURL = nil
        onStateChange?(state)
        if let failedURL { onSettled?(failedURL, .cancelled) }
    }
}

/// 安全作用域与任务共同持有；URL 来自 App 私有目录时 start 返回 false 也可继续读取。
private final class SourceAccess: @unchecked Sendable {
    let url: URL
    private let scoped: Bool
    init(_ url: URL) { self.url = url; scoped = url.startAccessingSecurityScopedResource() }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}
