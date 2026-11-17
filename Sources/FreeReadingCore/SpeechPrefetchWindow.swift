import Foundation

/// 随播放位置前移的有界预取窗口。归属按书籍导入批次与音色隔离，不随每句播放器代次失效。
public struct SpeechPrefetchWindow: Sendable {
    public struct Ticket: Equatable, Sendable {
        public let generation: UInt64
        public let session: PlaybackCoordinator.Session
        public let voiceID: String
    }
    /// 同一窗口内的每次工作也有独立身份，旧任务退出不能清掉重试后新建的任务。
    public struct Work: Equatable, Sendable {
        public let ticket: Ticket
        private let id: UUID
        fileprivate init(ticket: Ticket) { self.ticket = ticket; id = UUID() }
    }
    public private(set) var ticket: Ticket?
    public private(set) var currentIndex = 0
    public private(set) var sentenceCount = 0
    private var generation: UInt64 = 0
    private var speed = 1.0
    private var durations: [Int: Double] = [:]
    private var activeWork: Work?
    private let horizon = 12
    private let playbackSeconds = 12.0

    public init() {}

    /// 同一归属的自然前移保留在途预取；明确跳转由调用方先 reset。
    @discardableResult
    public mutating func advance(session: PlaybackCoordinator.Session, voiceID: String, index: Int, sentenceCount: Int, speed: Double) -> Ticket {
        if ticket?.session != session || ticket?.voiceID != voiceID || index < currentIndex {
            reset()
            ticket = Ticket(generation: generation, session: session, voiceID: voiceID)
        }
        self.sentenceCount = max(0, sentenceCount)
        currentIndex = min(max(0, index), max(0, sentenceCount - 1))
        self.speed = speed.isFinite ? min(2, max(0.5, speed)) : 1
        durations = durations.filter { $0.key > currentIndex && $0.key <= upperIndex }
        return ticket!
    }

    public func accepts(_ candidate: Ticket) -> Bool { ticket == candidate }

    /// 工作归属与 Task 引用分开裁决：旧窗口的 Task 尚未退出时，新窗口也能立即排入补充工作。
    public mutating func beginWork() -> Work? {
        guard let ticket, nextTarget != nil else { return nil }
        guard activeWork?.ticket != ticket else { return nil }
        let work = Work(ticket: ticket)
        activeWork = work
        return work
    }

    public func accepts(_ work: Work) -> Bool { activeWork == work && ticket == work.ticket }

    /// 只有当前工作能清除 Controller 的 Task 句柄；旧窗口／旧重试的迟到清理直接忽略。
    @discardableResult
    public mutating func endWork(_ work: Work) -> Bool {
        guard activeWork == work else { return false }
        activeWork = nil
        return true
    }

    /// 最多 12 句，且达到约 12 秒实际播放储备后暂停补充；长句不会引发整章等待。
    public var nextTarget: Int? {
        guard ticket != nil, currentIndex + 1 < sentenceCount else { return nil }
        var seconds = 0.0
        for index in (currentIndex + 1)...upperIndex {
            guard let duration = durations[index] else { return index }
            seconds += duration / speed
            if seconds >= playbackSeconds { return nil }
        }
        return nil
    }

    @discardableResult
    public mutating func record(index: Int, duration: Double, ticket: Ticket) -> Bool {
        guard accepts(ticket), duration.isFinite, duration > 0,
              index > currentIndex, index < sentenceCount, index <= upperIndex else { return false }
        durations[index] = duration
        return true
    }

    public var retainedIndices: Set<Int> { Set(durations.keys) }
    private var upperIndex: Int { currentIndex + min(horizon, max(0, sentenceCount - currentIndex - 1)) }

    public mutating func reset() {
        generation &+= 1; ticket = nil; activeWork = nil
        durations = [:]; sentenceCount = 0; currentIndex = 0
    }
}
