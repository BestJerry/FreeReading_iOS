import Foundation

/// 当前要播放的语音优先于预取；播放接管同一句预取时不重新合成。
public enum SpeechPreparationPriority: Sendable { case playback, prefetch }

/// 实际合成任务共用的串行队列：同键单飞、按播放优先级调度，取消仅作用于对应请求。
/// produce 必须响应取消，并在发布文件前再次检查取消状态。
@MainActor
public final class SpeechPreparationQueue<Key: Hashable & Sendable, Value: Sendable> {
    public typealias Producer = @MainActor () async throws -> Value

    private struct Waiter {
        let priority: SpeechPreparationPriority
        let continuation: CheckedContinuation<Value, Error>
    }
    private final class Request {
        let id = UUID()
        let key: Key
        let produce: Producer
        var waiters: [UUID: Waiter] = [:]
        var task: Task<Void, Never>?
        var cancelled = false
        var priority: SpeechPreparationPriority {
            waiters.values.contains { $0.priority == .playback } ? .playback : .prefetch
        }
        init(key: Key, produce: @escaping Producer) { self.key = key; self.produce = produce }
    }
    private var requests: [Key: Request] = [:]
    private var pending: [Request] = []
    private var running: Request?

    public init() {}

    /// 用于诊断合并请求和取消；不暴露内部 continuation 或生产任务。
    func waitingConsumers(for key: Key) -> Int { requests[key]?.waiters.count ?? 0 }

    /// 请求同键结果时加入原任务；调用者单独取消不会误杀其他等待方。
    public func value(for key: Key, priority: SpeechPreparationPriority = .playback,
                      produce: @escaping Producer) async throws -> Value {
        try Task.checkCancellation()
        let waiterID = UUID()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let request: Request
                if let existing = requests[key] { request = existing }
                else {
                    request = Request(key: key, produce: produce)
                    requests[key] = request; pending.append(request)
                }
                request.waiters[waiterID] = Waiter(priority: priority, continuation: continuation)
                schedule()
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.cancelWaiter(key: key, id: waiterID) }
        }
        try Task.checkCancellation()
        return result
    }

    /// 手动定位、换书或换声时取消全部工作。旧任务完全退出前不启动新合成器。
    public func cancelAll() {
        for request in Array(requests.values) { cancel(request) }
        schedule()
    }

    /// 移除书籍时只取消它的工作，不能中断另一本书正在播放的准备。
    public func cancel(where matches: (Key) -> Bool) {
        for request in Array(requests.values) where matches(request.key) { cancel(request) }
        schedule()
    }

    private func cancelWaiter(key: Key, id: UUID) {
        guard let request = requests[key], let waiter = request.waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        if request.waiters.isEmpty { cancel(request) }
        schedule()
    }

    private func cancel(_ request: Request) {
        guard !request.cancelled else { return }
        request.cancelled = true
        if requests[request.key]?.id == request.id { requests[request.key] = nil }
        pending.removeAll { $0.id == request.id }
        let waiters = Array(request.waiters.values); request.waiters.removeAll()
        request.task?.cancel()
        for waiter in waiters { waiter.continuation.resume(throwing: CancellationError()) }
    }

    private func schedule() {
        // 已被播放接管的预取，其有效优先级变为 playback，不能再被其他预取或排队请求抢占。
        if let running, !running.cancelled, running.priority == .prefetch,
           pending.contains(where: { $0.priority == .playback }) {
            cancel(running)
        }
        guard running == nil, !pending.isEmpty else { return }
        let index = pending.firstIndex(where: { $0.priority == .playback }) ?? 0
        let request = pending.remove(at: index)
        running = request
        request.task = Task { @MainActor [weak self] in
            let result: Result<Value, Error>
            do {
                try Task.checkCancellation()
                let value = try await request.produce()
                try Task.checkCancellation()
                result = .success(value)
            } catch { result = .failure(error) }
            self?.complete(request, result: result)
        }
    }

    private func complete(_ request: Request, result: Result<Value, Error>) {
        guard running?.id == request.id else { return }
        running = nil; request.task = nil
        if requests[request.key]?.id == request.id { requests[request.key] = nil }
        let waiters = Array(request.waiters.values); request.waiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(with: request.cancelled ? .failure(CancellationError()) : result)
        }
        schedule()
    }
}
