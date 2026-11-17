import Foundation

/// 播放副作用的裁决器。系统音频留在 App 层，代次、暂停意图及异步结果归属只由此处决定。
public struct PlaybackCoordinator: Sendable {
    public struct Session: Equatable, Sendable {
        public let bookID: String
        public let addedAt: Date
        public init(bookID: String, addedAt: Date) { self.bookID = bookID; self.addedAt = addedAt }
    }

    /// 同一本书删除再导入也属于新会话；书籍批次与代次共同拒绝迟到回调。
    public struct Ticket: Equatable, Sendable {
        public let generation: UInt64
        public let session: Session
    }

    public struct Preparation: Equatable, Sendable {
        public enum Transition: Equatable, Sendable { case explicit, continuous }
        public let ticket: Ticket
        public let position: SentencePosition
        public let fraction: Double?
        public let transition: Transition
    }

    public struct Seek: Equatable, Sendable {
        public let ticket: Ticket
        public let anchor: SentencePosition
        public let delta: Double
    }

    /// 保存时捕获会话身份，之后切书或停止都不能把旧游标写给新书。
    public struct Checkpoint: Equatable, Sendable {
        public let session: Session
        public let position: SentencePosition
    }

    public enum Phase: Equatable, Sendable { case idle, preparing, ready, ended, failed }
    public enum Completion: Equatable, Sendable { case ignored, advance(Int), finished }

    public private(set) var session: Session?
    public private(set) var sentenceCount = 0
    public private(set) var generation: UInt64 = 0
    public private(set) var wantsPlayback = false
    public private(set) var phase: Phase = .idle
    public private(set) var position = SentencePosition(index: 0, offset: 0)
    public private(set) var duration: Double = 0
    public private(set) var pendingSeek: Seek?
    private var voiceFraction: Double?
    private var resumeAfterInterruption = false

    public init() { }

    /// 失败后的播放器不能仅靠再次 play 恢复：必须重建准备代次，使后续完成回调仍可续播。
    public var canResumeInstalledPlayer: Bool { phase == .ready }

    /// 临时失败后保留可恢复的句内偏移；失败已发生在句末时重试本句，避免只播放最后几毫秒。
    public func recoveryPosition(at current: SentencePosition, duration: Double) -> SentencePosition? {
        guard phase == .failed else { return nil }
        var recovered = sanitized(current)
        if duration.isFinite, duration > 0, recovered.offset >= max(0, duration - 0.02) { recovered.offset = 0 }
        return recovered
    }

    public mutating func open(bookID: String, addedAt: Date, sentenceCount: Int) {
        let next = Session(bookID: bookID, addedAt: addedAt)
        if session != next { invalidate(); position = .init(index: 0, offset: 0); duration = 0; wantsPlayback = false }
        session = next
        self.sentenceCount = max(0, sentenceCount)
    }

    /// 普通定位和章按钮清除连续 seek/换声锚点，nil 播放意图表示保留暂停状态。
    public mutating func prepare(at target: SentencePosition, autoplay: Bool?) -> Preparation? {
        guard let ticket = begin(at: target, autoplay: autoplay) else { return nil }
        pendingSeek = nil; voiceFraction = nil; resumeAfterInterruption = false
        return Preparation(ticket: ticket, position: position, fraction: nil, transition: .explicit)
    }

    /// 自然播放完成只更换播放器代次，不能因此撤销同书同音色的下一句预合成。
    /// 准备期间的用户暂停仍是最新意图，移交不重新写入 autoplay=true。
    public mutating func continueAfterCompletion(to index: Int) -> Preparation? {
        guard phase == .ready, wantsPlayback, index == position.index + 1, index < sentenceCount,
              let ticket = begin(at: .init(index: index, offset: 0), autoplay: nil) else { return nil }
        pendingSeek = nil; voiceFraction = nil; resumeAfterInterruption = false
        return Preparation(ticket: ticket, position: position, fraction: nil, transition: .continuous)
    }

    /// 多次快进在同一原始游标累加；旧操作即使忽略取消完成，也不能再安装播放器。
    public mutating func seek(by delta: Double, from current: SentencePosition) -> Seek? {
        guard delta.isFinite else { return nil }
        let anchor = pendingSeek?.anchor ?? sanitized(current)
        let accumulated = min(3_600, max(-3_600, (pendingSeek?.delta ?? 0) + min(3_600, max(-3_600, delta))))
        guard let ticket = begin(at: anchor, autoplay: nil) else { return nil }
        let seek = Seek(ticket: ticket, anchor: anchor, delta: accumulated)
        pendingSeek = seek; voiceFraction = nil; resumeAfterInterruption = false
        return seek
    }

    /// 连续换声时保留首次句内比例，不能因为中间快照时长归零而丢失原位置。
    public mutating func changeVoice(from current: SentencePosition, duration currentDuration: Double) -> Preparation? {
        let fraction = voiceFraction ?? (currentDuration.isFinite && currentDuration > 0 ? min(1, max(0, current.offset / currentDuration)) : nil)
        guard let ticket = begin(at: current, autoplay: nil) else { return nil }
        voiceFraction = fraction; pendingSeek = nil; resumeAfterInterruption = false
        return Preparation(ticket: ticket, position: position, fraction: fraction, transition: .explicit)
    }

    public func accepts(_ ticket: Ticket) -> Bool { session == ticket.session && generation == ticket.generation && phase != .idle }

    /// 安装结果以“现在”的播放意图为准，准备开始时的 autoplay 不能覆盖期间按下的暂停。
    @discardableResult
    public mutating func install(_ ticket: Ticket, at target: SentencePosition, duration: Double, fraction: Double? = nil) -> SentencePosition? {
        guard accepts(ticket), phase == .preparing, duration.isFinite, duration > 0 else { return nil }
        let requested = fraction.map { $0 * duration } ?? target.offset
        position = sanitized(.init(index: target.index, offset: min(max(0, requested.isFinite ? requested : 0), max(0, duration - 0.005))))
        self.duration = duration; phase = .ready; pendingSeek = nil; voiceFraction = nil
        return position
    }

    public mutating func setPlaybackIntent(_ play: Bool) {
        guard session != nil else { return }
        wantsPlayback = play; resumeAfterInterruption = false
    }

    public mutating func pause() { setPlaybackIntent(false) }

    /// 系统上一项／下一项只移动一句；首尾不绕回，保留暂停状态。
    public mutating func moveSentence(by delta: Int, from currentIndex: Int) -> Preparation? {
        guard sentenceCount > 0, delta != 0 else { return nil }
        let current = min(max(0, currentIndex), sentenceCount - 1)
        let target = delta > 0 ? current + 1 : current - 1
        guard (0..<sentenceCount).contains(target) else { return nil }
        return prepare(at: .init(index: target, offset: 0), autoplay: nil)
    }

    public mutating func interrupt() {
        resumeAfterInterruption = resumeAfterInterruption || wantsPlayback
        wantsPlayback = false
    }

    /// 只有系统准许且用户在中断后没有主动暂停／换位时才恢复。
    @discardableResult
    public mutating func endInterruption(shouldResume: Bool) -> Bool {
        let resume = resumeAfterInterruption && shouldResume && session != nil
        resumeAfterInterruption = false
        if resume { wantsPlayback = true }
        return resume
    }

    public mutating func complete(_ ticket: Ticket, successfully: Bool) -> Completion {
        guard accepts(ticket), phase == .ready else { return .ignored }
        position.offset = duration
        if successfully && wantsPlayback && position.index + 1 < sentenceCount { return .advance(position.index + 1) }
        wantsPlayback = false; phase = successfully ? .ended : .failed; resumeAfterInterruption = false
        return .finished
    }

    public mutating func fail(_ ticket: Ticket? = nil) {
        if let ticket, !accepts(ticket) { return }
        wantsPlayback = false; phase = .failed; pendingSeek = nil; voiceFraction = nil; resumeAfterInterruption = false
    }

    public func checkpoint(at current: SentencePosition) -> Checkpoint? {
        guard let session, sentenceCount > 0 else { return nil }
        return Checkpoint(session: session, position: sanitized(current))
    }

    public mutating func stop() {
        invalidate(); session = nil; sentenceCount = 0; wantsPlayback = false
        position = .init(index: 0, offset: 0); duration = 0; phase = .idle
    }

    private mutating func begin(at target: SentencePosition, autoplay: Bool?) -> Ticket? {
        guard let session, sentenceCount > 0 else { return nil }
        generation &+= 1
        if let autoplay { wantsPlayback = autoplay }
        position = sanitized(target); duration = 0; phase = .preparing
        return Ticket(generation: generation, session: session)
    }

    private mutating func invalidate() {
        generation &+= 1; pendingSeek = nil; voiceFraction = nil; resumeAfterInterruption = false
    }

    private func sanitized(_ value: SentencePosition) -> SentencePosition {
        SentencePosition(index: min(max(0, value.index), max(0, sentenceCount - 1)), offset: max(0, value.offset.isFinite ? value.offset : 0))
    }
}
