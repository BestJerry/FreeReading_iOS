import Foundation

/// 每次明确开始或恢复朗读产生一次事件；自然换句沿用原事件，不覆盖本次播放中的手动关闭。
public struct PlaybackFollowRequest: Equatable, Sendable {
    public static let preferenceKey = "reader.followAudio"
    public let id: UUID
    public let bookID: String
    public let addedAt: Date
    public init(bookID: String, addedAt: Date, id: UUID = UUID()) {
        self.id = id; self.bookID = bookID; self.addedAt = addedAt
    }

    /// 起播方已同步开启偏好；延迟消费时保留用户在起播之后再次关闭的最新选择。
    /// nil 表示其他书、旧导入批次或已消费事件，不得改变阅读状态。
    public func followingPreference(bookID: String, addedAt: Date, after previous: PlaybackFollowRequest?, currentPreference: Bool) -> Bool? {
        guard self.bookID == bookID, self.addedAt == addedAt, id != previous?.id else { return nil }
        return currentPreference
    }
}
