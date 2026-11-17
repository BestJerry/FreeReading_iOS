import Foundation

/// 只串行化修改书库目录的操作；等待锁的任务可取消，不占住仓库 actor 的进度保存通道。
actor RepositoryMutationGate {
    private var owner: UUID?
    private var waiters: [(UUID, CheckedContinuation<UUID, Error>)] = []
    func acquire() async throws -> UUID {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if owner == nil { owner = id; continuation.resume(returning: id) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
    func release(_ id: UUID) {
        guard owner == id else { return }
        if waiters.isEmpty { owner = nil }
        else {
            let next = waiters.removeFirst(); owner = next.0; next.1.resume(returning: next.0)
        }
    }
}

/// 同一根目录的多个仓库实例也共享修改锁，避免测试、导入入口或扩展并发覆盖书籍目录。
final class RepositoryProcessState: @unchecked Sendable {
    static let shared = RepositoryProcessState()
    private let lock = NSLock()
    private var gates: [String: RepositoryMutationGate] = [:]
    private var active: Set<String> = []
    private func key(_ url: URL) -> String {
        // contentsOfDirectory 与 isDirectory URL 的末尾斜杠形式可能不同，统一后再登记。
        "/" + url.standardizedFileURL.resolvingSymlinksInPath().path.split(separator: "/").joined(separator: "/")
    }
    func gate(for root: URL) -> RepositoryMutationGate {
        lock.lock(); defer { lock.unlock() }
        let path = key(root)
        if let gate = gates[path] { return gate }
        let gate = RepositoryMutationGate(); gates[path] = gate; return gate
    }
    func activate(_ directory: URL) { lock.lock(); active.insert(key(directory)); lock.unlock() }
    func deactivate(_ directory: URL) { lock.lock(); active.remove(key(directory)); lock.unlock() }

    /// 进程崩溃后没有活跃登记；仅清理受控前缀，另一个实例正在使用的目录会保留。
    func recoverTemporaryDirectories(in root: URL) {
        lock.lock(); defer { lock.unlock() }
        let files = FileManager.default
        for base in [root, root.appendingPathComponent("books")] {
            for child in (try? files.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
                let name = child.lastPathComponent
                if (name.hasPrefix(".import-") || name.hasPrefix(".trash-")), !active.contains(key(child)) {
                    try? files.removeItem(at: child)
                }
            }
        }
    }
}

/// 同步登记退出时的最终 DOM 保存；只在轻量开书时等待，不用于听书索引加载。
final class ReadingSaveRegistry: @unchecked Sendable {
    struct Entry: Sendable { var id: UUID; var bookID: String; var addedAt: Date; var task: Task<Void, Never> }
    private let lock = NSLock()
    private var entries: [Entry] = []
    func register(bookID: String, addedAt: Date, task: Task<Void, Never>) {
        let id = UUID()
        lock.lock(); entries.append(Entry(id: id, bookID: bookID, addedAt: addedAt, task: task)); lock.unlock()
        Task { [weak self] in
            await task.value
            self?.finish([id])
        }
    }
    func pending(bookID: String, addedAt: Date) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.bookID == bookID && $0.addedAt == addedAt }
    }
    func finish(_ ids: Set<UUID>) { lock.lock(); entries.removeAll { ids.contains($0.id) }; lock.unlock() }
    func remove(bookID: String) { lock.lock(); entries.removeAll { $0.bookID == bookID }; lock.unlock() }
}
