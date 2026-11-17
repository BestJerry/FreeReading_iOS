import Foundation
import Combine

/// 只有持续等待音频时才显示缓冲提示；短暂切句不把播放／暂停控件变成转圈。
/// 延迟函数可注入，回归测试可精确推进等待与取消，无须调用系统 TTS 或真实计时。
@MainActor
public final class PlaybackLoadingPresentation: ObservableObject {
    @Published public private(set) var isVisible = false
    private let wait: @Sendable () async throws -> Void
    private var pending: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var waiting = false

    public init(wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(300)) }) {
        self.wait = wait
    }

    deinit { pending?.cancel() }

    /// 重复的播放快照不重启延迟，暂停／准备完成会立即撤掉提示并拒绝迟到结果。
    public func update(isPreparing: Bool, wantsPlayback: Bool) {
        let shouldWait = isPreparing && wantsPlayback
        guard shouldWait != waiting else { return }
        waiting = shouldWait; generation &+= 1
        pending?.cancel(); pending = nil
        isVisible = false
        guard shouldWait else { return }
        let token = generation, delay = wait
        pending = Task { [weak self] in
            do { try await delay() } catch { return }
            guard !Task.isCancelled, let self, self.waiting, self.generation == token else { return }
            self.isVisible = true; self.pending = nil
        }
    }

    public func cancel() {
        waiting = false; generation &+= 1
        pending?.cancel(); pending = nil
        isVisible = false
    }
}
