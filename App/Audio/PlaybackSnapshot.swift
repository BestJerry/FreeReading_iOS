import Foundation
import FreeReadingCore

/// 播放服务对外的不可变快照；章节进度表示正文位置，不假设整章音频已生成。
struct PlaybackSnapshot: Equatable {
    var bookID: String?
    var sentenceIndex = 0
    var chapterIndex = 0
    var text = ""
    var isPlaying = false
    var isPreparing = false
    var wantsPlayback = false
    var position: Double = 0
    var duration: Double = 0
    var speed: Float = 1
    var chapterProgress: Double = 0
    var error: String?
    var voiceName = "自动选择"
    var canGoToPreviousChapter = false
    var canGoToNextChapter = false
    var followRequest: PlaybackFollowRequest?
}

/// 来自系统已提供的声音；iOS 不公开逐个声音是否需要下载的可靠标志。
struct VoiceOption: Identifiable, Equatable {
    let id: String
    let name: String
    let language: String
    var availabilityText = "尚未验证可合成"
    // 系统列表及一次联网合成都不等于离线能力，不能标成“已下载离线声音”。
    var offlineText = "iOS 不提供可靠的离线音色筛选；离线使用请下载声音后断网验证。"
}

/// 用于播放和跨句时间定位的实际音频文件与秒数。
struct CachedSpeechClip: Sendable {
    let url: URL
    let duration: Double
}

enum SpeechPlaybackError: LocalizedError {
    case noVoice(String)
    case emptyText
    case synthesisFailed
    case timedOut
    case invalidAudio
    case cacheFull

    var errorDescription: String? {
        switch self {
        case .noVoice(let language):
            return "没有可用的\(language)系统声音。请在“设置 → 辅助功能 → 朗读内容 → 声音”下载对应声音后重试。"
        case .emptyText: return "当前位置没有可朗读文字，请选择正文。"
        case .synthesisFailed: return "系统语音合成失败，请检查已安装的声音后重试。"
        case .timedOut: return "准备语音超时，请确认系统声音已下载后重试。"
        case .invalidAudio: return "系统语音没有生成可播放的音频，请切换声音后重试。"
        case .cacheFull: return "语音缓存空间不足，请释放设备存储后重试。"
        }
    }
}
