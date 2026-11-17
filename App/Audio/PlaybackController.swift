import AVFoundation
import Combine
import FreeReadingCore
import MediaPlayer
import UIKit

/// 应用级听书控制器；页面只发送命令，合成、播放器与媒体会话始终由该实例持有。
@MainActor
final class PlaybackController: NSObject, ObservableObject {
    @Published private(set) var snapshot: PlaybackSnapshot
    private(set) var book: SpeechBook?

    private let repository: BookRepository
    private let cache = SpeechAudioCache()
    private var player: AVAudioPlayer?
    private var timeline: PlaybackTimeline?
    private var generation: UInt64 = 0
    private var operation: Task<Void, Never>?
    private var prefetch: Task<Void, Never>?
    private var shouldPlay = false
    private var currentClipURL: URL?
    private var prefetchedURLs: [URL] = []
    private var timer: Timer?
    private var lastSaved = ProcessInfo.processInfo.systemUptime
    private var observers: [NSObjectProtocol] = []
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var interruptedPlayback = false
    private var artwork: MPMediaItemArtwork?
    private var pendingSeek: (anchor: SentencePosition, delta: Double)?

    init(repository: BookRepository) {
        self.repository = repository
        let saved = UserDefaults.standard.float(forKey: "FreeReading.playback.speed")
        snapshot = PlaybackSnapshot(speed: saved.isFinite && (0.5...2).contains(saved) ? saved : 1)
        super.init()
        configureRemoteCommands()
        observeAudioSession()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    deinit {
        timer?.invalidate()
        operation?.cancel()
        prefetch?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for (command, target) in remoteTargets { command.removeTarget(target) }
    }

    /// 明确的书籍／句子选择建立新代次；先捕获旧书位置，再替换书籍，避免跨书保存。
    func start(book newBook: SpeechBook, sentenceIndex: Int, offset: Double = 0) {
        guard !newBook.sentences.isEmpty else { return }
        saveCurrent()
        let changedBook = book?.record.id != newBook.record.id
        book = newBook
        if changedBook { timeline = nil; artwork = nil; loadArtwork(for: newBook) }
        pendingSeek = nil
        interruptedPlayback = false
        prepare(index: min(max(0, sentenceIndex), newBook.sentences.count - 1), offset: offset, autoplay: true)
    }

    /// 准备期间也记录最新播放意图；稍后音频到达时不能覆盖用户刚按下的暂停。
    func toggle() {
        guard book != nil else { return }
        if snapshot.isPreparing {
            shouldPlay.toggle()
            interruptedPlayback = false
            refreshSnapshot()
        } else if shouldPlay && player?.isPlaying == true {
            pause()
        } else if let player, player.currentTime < max(0, player.duration - 0.02) {
            do {
                try activateSession()
                shouldPlay = true
                interruptedPlayback = false
                snapshot.error = nil
                guard player.play() else { throw SpeechPlaybackError.invalidAudio }
                refreshSnapshot()
            } catch { fail(error) }
        } else {
            prepare(index: snapshot.sentenceIndex, offset: snapshot.error == nil ? 0 : snapshot.position, autoplay: true)
        }
    }

    func pause() {
        shouldPlay = false
        interruptedPlayback = false
        player?.pause()
        refreshSnapshot()
        saveCurrent()
    }

    /// 停止立即清除会话并使所有旧结果失效；捕获的进度交由书库按更新时间保存。
    func stop() {
        saveCurrent()
        replaceWork()
        shouldPlay = false
        interruptedPlayback = false
        pendingSeek = nil
        book = nil
        timeline = nil
        artwork = nil
        snapshot = PlaybackSnapshot(speed: snapshot.speed)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        updateRemoteAvailability()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 书架移除书籍时调用，保证音频不再引用待删除的缓存。
    func removeCachedAudio(bookID: String) {
        if book?.record.id == bookID { stop() }
        cache.remove(bookID: bookID)
    }

    /// 准备中的连续快进／快退从相同起点累加位移，未知句长按需合成取得真实秒数。
    func seek(by delta: Double) {
        guard let currentBook = book, delta.isFinite else { return }
        saveCurrent()
        let previous = pendingSeek
        let anchor = previous?.anchor ?? SentencePosition(index: snapshot.sentenceIndex, offset: currentPosition())
        let accumulated = min(3_600, max(-3_600, (previous?.delta ?? 0) + min(3_600, max(-3_600, delta))))
        pendingSeek = (anchor, accumulated)
        let token = replaceWork()
        snapshot.isPreparing = true
        snapshot.isPlaying = false
        snapshot.wantsPlayback = shouldPlay
        snapshot.error = nil
        updateNowPlaying()
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try self.activateSession()
                try await self.ensureTimeline(currentBook, token: token)
                let voice = try self.cache.effectiveVoice(language: currentBook.record.language)
                let target = try await PlaybackTimeline.seek(sentenceCount: currentBook.sentences.count, from: anchor, by: accumulated) { index in
                    try await self.cache.ensure(bookID: currentBook.record.id, text: currentBook.text(at: index), voice: voice).duration
                }
                try self.check(token)
                self.pendingSeek = nil
                self.publishTarget(target.index, offset: target.offset)
                try await self.install(index: target.index, offset: target.offset, fraction: nil, voice: voice, token: token)
            } catch is CancellationError { }
            catch { if token == self.generation { self.fail(error) } }
            if token == self.generation { self.operation = nil }
        }
    }

    func previousChapter() { moveChapter(forward: false) }
    func nextChapter() { moveChapter(forward: true) }

    func setSpeed(_ speed: Float) {
        guard speed.isFinite else { return }
        snapshot.speed = min(2, max(0.5, speed))
        UserDefaults.standard.set(snapshot.speed, forKey: "FreeReading.playback.speed")
        player?.rate = snapshot.speed
        refreshSnapshot()
    }

    func availableVoices(language: String) -> [VoiceOption] {
        cache.voices(language: language).map { VoiceOption(id: $0.identifier, name: $0.name, language: $0.language) }
    }

    func selectedVoiceID(language: String) -> String? { cache.selectedID(language: language) }

    /// 音色偏好按语言保存；当前书籍换声时按句内比例恢复，并保留最新播放／暂停状态。
    func selectVoice(id: String?, language: String) {
        let appliesToCurrent = book.map { SpeechAudioCache.languageKey($0.record.language) == SpeechAudioCache.languageKey(language) } ?? false
        let ratio: Double? = snapshot.duration > 0 ? min(1, max(0, currentPosition() / snapshot.duration)) : nil
        cache.select(id: id, language: language)
        if appliesToCurrent {
            saveCurrent()
            pendingSeek = nil
            prepare(index: snapshot.sentenceIndex, offset: snapshot.position, autoplay: nil, fraction: ratio)
        }
    }

    private func moveChapter(forward: Bool) {
        guard let timeline else { return }
        let target = forward ? timeline.nextChapter(at: snapshot.sentenceIndex) : timeline.previousChapter(at: snapshot.sentenceIndex)
        guard let target else { return }
        saveCurrent()
        pendingSeek = nil
        interruptedPlayback = false
        prepare(index: target, offset: 0, autoplay: true)
    }

    /// 清空旧播放器后设置初始播放意图；合成挂起期间的 pause() 具有最终决定权。
    private func prepare(index: Int, offset: Double, autoplay: Bool?, fraction: Double? = nil) {
        guard let currentBook = book, currentBook.sentences.indices.contains(index) else { return }
        let token = replaceWork()
        if let autoplay { shouldPlay = autoplay }
        publishTarget(index, offset: offset)
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try self.activateSession()
                try await self.ensureTimeline(currentBook, token: token)
                self.publishTarget(index, offset: offset)
                let voice = try self.cache.effectiveVoice(language: currentBook.record.language)
                try await self.install(index: index, offset: offset, fraction: fraction, voice: voice, token: token)
            } catch is CancellationError { }
            catch { if token == self.generation { self.fail(error) } }
            if token == self.generation { self.operation = nil }
        }
    }

    @discardableResult
    private func replaceWork() -> UInt64 {
        generation &+= 1
        operation?.cancel()
        prefetch?.cancel()
        operation = nil
        prefetch = nil
        cache.cancel()
        player?.delegate = nil
        player?.stop()
        player = nil
        currentClipURL = nil
        prefetchedURLs = []
        cache.protect([])
        return generation
    }

    private func ensureTimeline(_ currentBook: SpeechBook, token: UInt64) async throws {
        if timeline == nil {
            let prepared = await Task.detached(priority: .userInitiated) { PlaybackTimeline(book: currentBook) }.value
            try check(token)
            timeline = prepared
        }
    }

    /// 只有当前代次可以安装播放器；句子序号与真实音频时间同步发布给原文页。
    private func install(index: Int, offset: Double, fraction: Double?, voice: AVSpeechSynthesisVoice, token: UInt64) async throws {
        guard let currentBook = book else { throw CancellationError() }
        let clip = try await cache.ensure(bookID: currentBook.record.id, text: currentBook.text(at: index), voice: voice)
        try check(token)
        let next = try AVAudioPlayer(contentsOf: clip.url)
        next.delegate = self
        next.enableRate = true
        next.rate = snapshot.speed
        guard next.prepareToPlay() else { throw SpeechPlaybackError.invalidAudio }
        let requested = fraction.map { $0 * clip.duration } ?? offset
        next.currentTime = min(max(0, requested.isFinite ? requested : 0), max(0, clip.duration - 0.005))
        player = next
        currentClipURL = clip.url
        cache.protect([clip.url])
        snapshot.sentenceIndex = index
        snapshot.duration = clip.duration
        snapshot.isPreparing = false
        snapshot.error = nil
        snapshot.voiceName = cache.selectedID(language: currentBook.record.language) == nil ? "自动 · \(voice.name)" : voice.name
        if shouldPlay {
            try activateSession()
            guard next.play() else { throw SpeechPlaybackError.invalidAudio }
        }
        refreshSnapshot()
        saveCurrent()
        launchPrefetch(currentBook, from: index, voice: voice, token: token)
    }

    /// 仅缓存接下来的两句，优先保证当前句开播，失败留待实际播放时展示和重试。
    private func launchPrefetch(_ currentBook: SpeechBook, from index: Int, voice: AVSpeechSynthesisVoice, token: UInt64) {
        guard index + 1 < currentBook.sentences.count else { return }
        prefetch = Task { [weak self] in
            guard let self else { return }
            do {
                for target in (index + 1)..<min(index + 3, currentBook.sentences.count) {
                    try self.check(token)
                    let clip = try await self.cache.ensure(bookID: currentBook.record.id, text: currentBook.text(at: target), voice: voice)
                    try self.check(token)
                    self.prefetchedURLs.append(clip.url)
                    self.cache.protect([self.currentClipURL].compactMap { $0 } + self.prefetchedURLs)
                }
            } catch { /* 预取不能抢占或中断当前播放。 */ }
            if token == self.generation { self.prefetch = nil }
        }
    }

    private func check(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard token == generation, book != nil else { throw CancellationError() }
    }

    private func publishTarget(_ index: Int, offset: Double) {
        guard let book, book.sentences.indices.contains(index) else { return }
        let sentence = book.sentences[index]
        snapshot.bookID = book.record.id
        snapshot.sentenceIndex = index
        snapshot.chapterIndex = sentence.chapterIndex
        snapshot.text = book.text(at: index)
        snapshot.position = offset.isFinite ? max(0, offset) : 0
        snapshot.duration = 0
        snapshot.isPreparing = true
        snapshot.isPlaying = false
        snapshot.wantsPlayback = shouldPlay
        snapshot.error = nil
        snapshot.chapterProgress = timeline?.fraction(at: index, offset: 0, duration: 0) ?? 0
        snapshot.canGoToPreviousChapter = timeline?.previousChapter(at: index) != nil
        snapshot.canGoToNextChapter = timeline?.nextChapter(at: index) != nil
        updateRemoteAvailability()
        updateNowPlaying()
    }

    private func currentPosition() -> Double { player?.currentTime ?? snapshot.position }

    private func refreshSnapshot() {
        guard book != nil else { return }
        snapshot.position = max(0, currentPosition())
        if let player { snapshot.duration = max(0, player.duration) }
        snapshot.isPlaying = player?.isPlaying == true
        snapshot.wantsPlayback = shouldPlay
        snapshot.chapterProgress = timeline?.fraction(at: snapshot.sentenceIndex, offset: snapshot.position, duration: snapshot.duration) ?? 0
        snapshot.canGoToPreviousChapter = timeline?.previousChapter(at: snapshot.sentenceIndex) != nil
        snapshot.canGoToNextChapter = timeline?.nextChapter(at: snapshot.sentenceIndex) != nil
        updateRemoteAvailability()
        updateNowPlaying()
    }

    private func tick() {
        guard book != nil, player?.isPlaying == true else { return }
        refreshSnapshot()
        if ProcessInfo.processInfo.systemUptime - lastSaved >= 2 { saveCurrent() }
    }

    /// 播放游标以句子定位保存；书库拒绝过期时间和已移除书籍的迟到写入。
    private func saveCurrent(positionOverride: Double? = nil) {
        guard let book, book.sentences.indices.contains(snapshot.sentenceIndex) else { return }
        let sentence = book.sentences[snapshot.sentenceIndex]
        let section = book.sections[sentence.sectionID]
        let progress = ReadingProgress(bookID: book.record.id, chapterIndex: sentence.chapterIndex,
            elementID: section.elementID, textOffset: sentence.range.start, sentenceIndex: snapshot.sentenceIndex,
            audioOffset: max(0, positionOverride ?? currentPosition()), updatedAt: Date())
        lastSaved = ProcessInfo.processInfo.systemUptime
        Task { [weak self, repository] in
            do { try await repository.saveProgress(progress, expectedAddedAt: book.record.addedAt) }
            catch {
                guard let self, self.book?.record.id == progress.bookID else { return }
                if self.snapshot.error == nil { self.snapshot.error = "进度暂时无法保存，请检查设备存储；当前音频可继续播放。" }
            }
        }
    }

    private func fail(_ error: Error) {
        shouldPlay = false
        player?.pause()
        snapshot.isPreparing = false
        snapshot.isPlaying = false
        snapshot.error = (error as? LocalizedError)?.errorDescription ?? "播放失败：\(error.localizedDescription)"
        refreshSnapshot()
        saveCurrent()
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [])
        try session.setActive(true)
    }

    /// 锁屏的时间轴使用当前已生成句子的真实媒体时间，应用内仍显示整章正文百分比。
    private func updateNowPlaying() {
        guard let book else { return }
        let chapter = book.chapters.first(where: { $0.id == snapshot.chapterIndex })?.title ?? "听书"
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: book.record.title,
            MPMediaItemPropertyArtist: book.record.author,
            MPMediaItemPropertyAlbumTitle: chapter,
            MPMediaItemPropertyPlaybackDuration: snapshot.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.position,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPlaying ? snapshot.speed : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: snapshot.speed,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for book: SpeechBook) {
        guard let path = book.record.coverPath,
              let image = UIImage(contentsOfFile: repository.bookDirectory(id: book.record.id).appendingPathComponent(path).path) else { return }
        artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand) { controller in if !controller.shouldPlay { controller.toggle() } }
        add(center.pauseCommand) { $0.pause() }
        add(center.togglePlayPauseCommand) { $0.toggle() }
        add(center.stopCommand) { $0.stop() }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        add(center.skipForwardCommand) { $0.seek(by: 15) }
        add(center.skipBackwardCommand) { $0.seek(by: -15) }
        add(center.nextTrackCommand) { $0.nextChapter() }
        add(center.previousTrackCommand) { $0.previousChapter() }
        center.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
        let rateTarget = center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let value = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in self?.setSpeed(value.playbackRate) }
            return .success
        }
        remoteTargets.append((center.changePlaybackRateCommand, rateTarget))
        let positionTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let value = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.seek(by: value.positionTime - self.currentPosition())
            }
            return .success
        }
        remoteTargets.append((center.changePlaybackPositionCommand, positionTarget))
        updateRemoteAvailability()
    }

    private func add(_ command: MPRemoteCommand, action: @escaping @MainActor (PlaybackController) -> Void) {
        let target = command.addTarget { [weak self] _ in
            guard self != nil else { return .commandFailed }
            Task { @MainActor [weak self] in if let self { action(self) } }
            return .success
        }
        remoteTargets.append((command, target))
    }

    private func updateRemoteAvailability() {
        let center = MPRemoteCommandCenter.shared()
        let active = book != nil
        let commands: [MPRemoteCommand] = [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.stopCommand,
                                          center.skipForwardCommand, center.skipBackwardCommand, center.changePlaybackRateCommand,
                                          center.changePlaybackPositionCommand]
        for command in commands { command.isEnabled = active }
        center.previousTrackCommand.isEnabled = active && snapshot.canGoToPreviousChapter
        center.nextTrackCommand.isEnabled = active && snapshot.canGoToNextChapter
    }

    private func observeAudioSession() {
        let notifications = NotificationCenter.default
        observers.append(notifications.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    let wasPlaying = self.shouldPlay
                    self.pause()
                    self.interruptedPlayback = wasPlaying
                } else if type == AVAudioSession.InterruptionType.ended.rawValue {
                    let resume = self.interruptedPlayback && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                    self.interruptedPlayback = false
                    if resume && !self.shouldPlay { self.toggle() }
                }
            }
        })
        observers.append(notifications.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor [weak self] in self?.pause() }
            }
        })
        observers.append(notifications.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.saveCurrent() }
        })
        observers.append(notifications.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.book != nil else { return }
                let position = self.currentPosition()
                self.saveCurrent()
                self.prepare(index: self.snapshot.sentenceIndex, offset: position, autoplay: self.shouldPlay)
            }
        })
    }
}

extension PlaybackController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player, let book = self.book else { return }
            self.snapshot.position = player.duration
            self.saveCurrent(positionOverride: player.duration)
            if flag && self.shouldPlay && self.snapshot.sentenceIndex + 1 < book.sentences.count {
                self.pendingSeek = nil
                self.prepare(index: self.snapshot.sentenceIndex + 1, offset: 0, autoplay: true)
            } else {
                self.shouldPlay = false
                self.player?.delegate = nil
                self.player = nil // AVAudioPlayer 完成后可能将 currentTime 归零，改为保留快照中的真实句末。
                self.snapshot.isPlaying = false
                self.snapshot.chapterProgress = self.timeline?.fraction(at: self.snapshot.sentenceIndex, offset: player.duration, duration: player.duration) ?? 1
                if !flag { self.snapshot.error = SpeechPlaybackError.invalidAudio.localizedDescription }
                self.refreshSnapshot()
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.fail(error ?? SpeechPlaybackError.invalidAudio)
        }
    }
}
