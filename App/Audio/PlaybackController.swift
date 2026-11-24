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
    private var coordinator = PlaybackCoordinator()
    private var playerTicket: PlaybackCoordinator.Ticket?
    private var operation: Task<Void, Never>?
    private var prefetch: Task<Void, Never>?
    private var shouldPlay: Bool { coordinator.wantsPlayback }
    private var currentClipURL: URL?
    private var prefetchWindow = SpeechPrefetchWindow()
    private var prefetchedClips: [Int: CachedSpeechClip] = [:]
    private struct PreparedNextPlayer {
        let index: Int
        let voiceID: String
        let session: PlaybackCoordinator.Session
        let player: AVAudioPlayer
    }
    private var preparedNextPlayer: PreparedNextPlayer?
    private var resolvedVoice: AVSpeechSynthesisVoice?
    private var resolvedVoiceName = "自动选择"
    private var audioSessionReady = false
    private var timer: Timer?
    private var lastSaved = ProcessInfo.processInfo.systemUptime
    private var observers: [NSObjectProtocol] = []
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var artwork: MPMediaItemArtwork?

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
        saveCurrent(final: true)
        let changedBook = book?.record.id != newBook.record.id || book?.record.addedAt != newBook.record.addedAt
        book = newBook
        if changedBook { timeline = nil; resolvedVoice = nil; artwork = nil; loadArtwork(for: newBook) }
        coordinator.open(bookID: newBook.record.id, addedAt: newBook.record.addedAt, sentenceCount: newBook.sentences.count)
        prepare(index: min(max(0, sentenceIndex), newBook.sentences.count - 1), offset: offset, autoplay: true)
    }

    /// 准备期间也记录最新播放意图；音频到达时以协调器中的最新暂停意图为准。
    func toggle() {
        guard book != nil else { return }
        if snapshot.isPreparing {
            coordinator.setPlaybackIntent(!shouldPlay)
            refreshSnapshot()
        } else if shouldPlay && player?.isPlaying == true {
            pause()
        } else {
            resumeCurrent()
        }
    }

    private func resumeCurrent() {
        coordinator.setPlaybackIntent(true)
        if snapshot.isPreparing { refreshSnapshot(); return }
        if coordinator.canResumeInstalledPlayer, let player, player.currentTime < max(0, player.duration - 0.02) {
            do {
                try activateSession()
                snapshot.error = nil
                guard player.play() else { throw SpeechPlaybackError.invalidAudio }
                refreshSnapshot()
            } catch { fail(error) }
        } else {
            let recovery = coordinator.recoveryPosition(at: .init(index: snapshot.sentenceIndex, offset: currentPosition()),
                                                        duration: player?.duration ?? snapshot.duration)
            prepare(index: snapshot.sentenceIndex, offset: recovery?.offset ?? (snapshot.error == nil ? 0 : snapshot.position), autoplay: true)
        }
    }

    func pause() {
        coordinator.pause()
        player?.pause()
        refreshSnapshot()
        saveCurrent(final: true)
    }

    /// 停止前捕获所属导入批次的进度，随后取消所有副作用并使迟到结果失效。
    func stop() {
        saveCurrent(final: true)
        coordinator.stop()
        replaceWork()
        book = nil
        timeline = nil
        artwork = nil
        snapshot = PlaybackSnapshot(speed: snapshot.speed)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        updateRemoteAvailability()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioSessionReady = false
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
        guard let seek = coordinator.seek(by: delta, from: .init(index: snapshot.sentenceIndex, offset: currentPosition())) else { return }
        let token = seek.ticket
        replaceWork()
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
                let voice = try self.voice(for: currentBook)
                let target = try await PlaybackTimeline.seek(sentenceCount: currentBook.sentences.count, from: seek.anchor, by: seek.delta) { index in
                    try await self.cache.ensure(bookID: currentBook.record.id, text: currentBook.text(at: index), voice: voice).duration
                }
                try self.check(token)
                self.publishTarget(target.index, offset: target.offset)
                try await self.install(index: target.index, offset: target.offset, fraction: nil, voice: voice, token: token)
            } catch is CancellationError { }
            catch { if self.coordinator.accepts(token) { self.fail(error) } }
            if self.coordinator.accepts(token) { self.operation = nil }
        }
    }

    func previousChapter() { moveChapter(forward: false) }
    func nextChapter() { moveChapter(forward: true) }

    func setSpeed(_ speed: Float) {
        guard speed.isFinite else { return }
        snapshot.speed = min(2, max(0.5, speed))
        UserDefaults.standard.set(snapshot.speed, forKey: "FreeReading.playback.speed")
        player?.rate = snapshot.speed
        preparedNextPlayer?.player.rate = snapshot.speed
        // 定位准备中快照仍可能指向旧句，不能因此为旧游标另建预取窗口。
        if coordinator.phase == .ready, !snapshot.isPreparing,
           let currentBook = book, let voice = resolvedVoice {
            launchPrefetch(currentBook, from: snapshot.sentenceIndex, voice: voice)
        }
        refreshSnapshot()
    }

    func availableVoices(language: String) -> [VoiceOption] {
        cache.voices(language: language).map {
            VoiceOption(id: $0.identifier, name: $0.name, language: $0.language,
                        availabilityText: cache.isValidated(voiceID: $0.identifier) ? "已验证可合成（本次运行）" : "尚未验证可合成")
        }
    }

    /// 从系统设置返回或用户点击刷新时重新枚举，失效的偏好由目录验证自动清除。
    @discardableResult
    func refreshVoices(language: String) -> [VoiceOption] {
        _ = cache.refreshVoices(language: language)
        // 刷新可能清除失效偏好；下一次定位重新解析，连续播放平时不重复枚举系统目录。
        resolvedVoice = nil
        return availableVoices(language: language)
    }

    func validateVoice(id: String, language: String) async throws {
        try await cache.validateVoice(id: id, language: language)
    }

    func selectedVoiceID(language: String) -> String? { cache.selectedID(language: language) }

    /// 音色偏好按语言保存；当前书籍换声时按句内比例恢复，并保留最新播放／暂停状态。
    func selectVoice(id: String?, language: String) {
        let appliesToCurrent = book.map { SpeechAudioCache.languageKey($0.record.language) == SpeechAudioCache.languageKey(language) } ?? false
        let current = SentencePosition(index: snapshot.sentenceIndex, offset: currentPosition())
        let duration = snapshot.duration
        cache.select(id: id, language: language)
        if appliesToCurrent {
            resolvedVoice = nil
            saveCurrent()
            if let preparation = coordinator.changeVoice(from: current, duration: duration) { execute(preparation) }
        }
    }

    private func moveChapter(forward: Bool) {
        guard let timeline else { return }
        let target = forward ? timeline.nextChapter(at: snapshot.sentenceIndex) : timeline.previousChapter(at: snapshot.sentenceIndex)
        guard let target else { return }
        saveCurrent()
        prepare(index: target, offset: 0, autoplay: true)
    }

    /// 锁屏和耳机的上一项／下一项按句切换，App 内独立的章按钮仍然从章首开播。
    private func moveSentence(by delta: Int) {
        guard book != nil else { return }
        saveCurrent()
        if let preparation = coordinator.moveSentence(by: delta, from: snapshot.sentenceIndex) {
            execute(preparation)
        }
    }

    private func prepare(index: Int, offset: Double, autoplay: Bool?) {
        guard let preparation = coordinator.prepare(at: .init(index: index, offset: offset), autoplay: autoplay) else { return }
        execute(preparation)
    }

    /// 显式定位取消旧工作；自然换句保留同一音色窗口，并同步接续已经准备好的播放器。
    private func execute(_ preparation: PlaybackCoordinator.Preparation) {
        guard let currentBook = book else { return }
        let token = preparation.ticket, index = preparation.position.index, offset = preparation.position.offset
        let continuous = preparation.transition == .continuous
        if continuous {
            operation?.cancel(); operation = nil
            // AVAudioPlayer.stop 会同步释放硬件；自然结束的播放器不再主动 stop。
            releaseCurrentPlayer(stopping: false)
        } else { replaceWork() }
        do {
            let voice = try voice(for: currentBook)
            if continuous, let window = prefetchWindow.ticket,
               window.session != coordinator.session || window.voiceID != voice.identifier {
                replaceWork()
            }
            if timeline != nil,
               let clip = prefetchedClips[index] ?? cache.cachedClip(bookID: currentBook.record.id, text: currentBook.text(at: index), voice: voice) {
                try installPreparedClip(clip, index: index, offset: offset, fraction: preparation.fraction, voice: voice, token: token)
                return
            }
            publishTarget(index, offset: offset)
            operation = Task { [weak self] in
                guard let self else { return }
                do {
                    try self.activateSession()
                    try await self.ensureTimeline(currentBook, token: token)
                    try await self.install(index: index, offset: offset, fraction: preparation.fraction, voice: voice, token: token)
                } catch is CancellationError { }
                catch { if self.coordinator.accepts(token) { self.fail(error) } }
                if self.coordinator.accepts(token) { self.operation = nil }
            }
        } catch {
            publishTarget(index, offset: offset)
            fail(error)
        }
    }

    /// 手动跳转、换声、切书和停止才撤销整个窗口；自然推进不调用此方法。
    private func replaceWork() {
        operation?.cancel(); operation = nil
        prefetch?.cancel(); prefetch = nil
        prefetchWindow.reset()
        cache.cancel()
        releaseCurrentPlayer(stopping: true)
        preparedNextPlayer = nil
        prefetchedClips = [:]
        cache.protect([])
    }

    private func releaseCurrentPlayer(stopping: Bool) {
        player?.delegate = nil
        if stopping { player?.stop() }
        player = nil; playerTicket = nil; currentClipURL = nil
    }

    private func voice(for currentBook: SpeechBook) throws -> AVSpeechSynthesisVoice {
        if let resolvedVoice { return resolvedVoice }
        let selected = cache.selectedID(language: currentBook.record.language)
        let voice = try cache.effectiveVoice(language: currentBook.record.language)
        resolvedVoice = voice
        resolvedVoiceName = selected == nil ? "自动 · \(voice.name)" : voice.name
        return voice
    }

    private func ensureTimeline(_ currentBook: SpeechBook, token: PlaybackCoordinator.Ticket) async throws {
        if timeline == nil {
            let prepared = await Task.detached(priority: .userInitiated) { PlaybackTimeline(book: currentBook) }.value
            try check(token)
            timeline = prepared
        }
    }

    /// 前台请求会接管同键的在途预取，而不是把它取消后重新合成。
    private func install(index: Int, offset: Double, fraction: Double?, voice: AVSpeechSynthesisVoice, token: PlaybackCoordinator.Ticket) async throws {
        guard let currentBook = book else { throw CancellationError() }
        let clip = try await cache.ensure(bookID: currentBook.record.id, text: currentBook.text(at: index), voice: voice, priority: .playback)
        try check(token)
        try installPreparedClip(clip, index: index, offset: offset, fraction: fraction, voice: voice, token: token)
    }

    /// 热缓存接续全程不发布 preparing，且优先使用播放期间已经 prepareToPlay 的下一句。
    private func installPreparedClip(_ clip: CachedSpeechClip, index: Int, offset: Double, fraction: Double?, voice: AVSpeechSynthesisVoice, token: PlaybackCoordinator.Ticket) throws {
        guard let currentBook = book else { throw CancellationError() }
        try check(token)
        let next: AVAudioPlayer
        if let prepared = preparedNextPlayer, prepared.index == index,
           prepared.voiceID == voice.identifier, prepared.session == coordinator.session {
            next = prepared.player
        } else { next = try makePlayer(for: clip) }
        preparedNextPlayer = nil
        guard let accepted = coordinator.install(token, at: .init(index: index, offset: offset), duration: clip.duration, fraction: fraction) else { throw CancellationError() }
        next.currentTime = accepted.offset
        next.delegate = self
        next.rate = snapshot.speed
        player = next; playerTicket = token; currentClipURL = clip.url
        let sentence = currentBook.sentences[index]
        snapshot.bookID = currentBook.record.id
        snapshot.sentenceIndex = index
        snapshot.chapterIndex = sentence.chapterIndex
        snapshot.text = currentBook.text(at: index)
        snapshot.position = accepted.offset
        snapshot.duration = clip.duration
        snapshot.isPreparing = false
        snapshot.error = nil
        snapshot.voiceName = resolvedVoiceName
        if shouldPlay {
            try activateSession()
            guard next.play() else { throw SpeechPlaybackError.invalidAudio }
        }
        launchPrefetch(currentBook, from: index, voice: voice)
        refreshSnapshot()
        saveCurrent()
    }

    private func makePlayer(for clip: CachedSpeechClip) throws -> AVAudioPlayer {
        let next = try AVAudioPlayer(contentsOf: clip.url)
        next.enableRate = true; next.rate = snapshot.speed
        guard next.prepareToPlay() else { throw SpeechPlaybackError.invalidAudio }
        return next
    }

    /// 小窗口按真实时长补足约 12 秒播放储备，最多 12 句；同一在途任务跨自然换句继续工作。
    private func launchPrefetch(_ currentBook: SpeechBook, from index: Int, voice: AVSpeechSynthesisVoice) {
        guard let session = coordinator.session else { return }
        let previousTicket = prefetchWindow.ticket
        let token = prefetchWindow.advance(session: session, voiceID: voice.identifier, index: index,
                                           sentenceCount: currentBook.sentences.count, speed: Double(snapshot.speed))
        if previousTicket != token {
            // 只撤销旧预取消费者；若前台已接管同句，单飞队列仍保留前台消费者的合成。
            prefetch?.cancel(); prefetch = nil
        }
        let retained = prefetchWindow.retainedIndices
        prefetchedClips = prefetchedClips.filter { retained.contains($0.key) }
        refreshCacheProtection()
        prepareNextPlayerIfAvailable(voice: voice, session: session)
        guard let work = prefetchWindow.beginWork() else { return }
        prefetch = Task { [weak self] in
            guard let self else { return }
            do {
                while self.prefetchWindow.accepts(work), let target = self.prefetchWindow.nextTarget {
                    try Task.checkCancellation()
                    let clip = try await self.cache.ensure(bookID: currentBook.record.id, text: currentBook.text(at: target), voice: voice, priority: .prefetch)
                    try Task.checkCancellation()
                    guard self.prefetchWindow.accepts(work) else { break }
                    if self.prefetchWindow.record(index: target, duration: clip.duration, ticket: token) {
                        self.prefetchedClips[target] = clip
                        self.refreshCacheProtection()
                        self.prepareNextPlayerIfAvailable(voice: voice, session: session)
                    }
                }
            } catch { /* 前台会在真正需要时重试，预取失败不停止当前音频。 */ }
            if self.prefetchWindow.endWork(work) { self.prefetch = nil }
        }
    }

    private func prepareNextPlayerIfAvailable(voice: AVSpeechSynthesisVoice, session: PlaybackCoordinator.Session) {
        let index = snapshot.sentenceIndex + 1
        if let prepared = preparedNextPlayer, prepared.index == index,
           prepared.voiceID == voice.identifier, prepared.session == session { return }
        preparedNextPlayer = nil
        guard let clip = prefetchedClips[index], let next = try? makePlayer(for: clip) else { return }
        preparedNextPlayer = PreparedNextPlayer(index: index, voiceID: voice.identifier, session: session, player: next)
    }

    private func refreshCacheProtection() {
        cache.protect([currentClipURL].compactMap { $0 } + prefetchedClips.values.map(\.url))
    }

    private func check(_ token: PlaybackCoordinator.Ticket) throws {
        try Task.checkCancellation()
        guard coordinator.accepts(token), book != nil else { throw CancellationError() }
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
    private func saveCurrent(positionOverride: Double? = nil, final: Bool = false) {
        guard let book,
              let checkpoint = coordinator.checkpoint(at: .init(index: snapshot.sentenceIndex, offset: positionOverride ?? currentPosition())),
              checkpoint.session.bookID == book.record.id, checkpoint.session.addedAt == book.record.addedAt,
              book.sentences.indices.contains(checkpoint.position.index) else { return }
        let sentence = book.sentences[checkpoint.position.index]
        let section = book.sections[sentence.sectionID]
        let progress = ReadingProgress(bookID: book.record.id, chapterIndex: sentence.chapterIndex,
            elementID: section.elementID, textOffset: sentence.range.start, sentenceIndex: checkpoint.position.index,
            audioOffset: checkpoint.position.offset, updatedAt: Date())
        lastSaved = ProcessInfo.processInfo.systemUptime
        let save = Task { [weak self, repository] in
            do { try await repository.saveProgress(progress, expectedAddedAt: checkpoint.session.addedAt) }
            catch {
                guard let self, self.book?.record.id == progress.bookID, self.book?.record.addedAt == checkpoint.session.addedAt else { return }
                if self.snapshot.error == nil { self.snapshot.error = "进度暂时无法保存，请检查设备存储；当前音频可继续播放。" }
            }
        }
        if final { repository.registerReadingSave(bookID: progress.bookID, expectedAddedAt: checkpoint.session.addedAt, task: save) }
    }

    private func fail(_ error: Error) {
        coordinator.fail()
        prefetch?.cancel(); prefetch = nil
        prefetchWindow.reset()
        preparedNextPlayer = nil; prefetchedClips = [:]
        cache.cancel()
        refreshCacheProtection()
        player?.pause()
        snapshot.isPreparing = false
        snapshot.isPlaying = false
        snapshot.error = (error as? LocalizedError)?.errorDescription ?? "播放失败：\(error.localizedDescription)"
        refreshSnapshot()
        saveCurrent()
    }

    private func activateSession() throws {
        guard !audioSessionReady else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [])
        try session.setActive(true)
        audioSessionReady = true
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
        add(center.nextTrackCommand) { $0.moveSentence(by: 1) }
        add(center.previousTrackCommand) { $0.moveSentence(by: -1) }
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
        center.previousTrackCommand.isEnabled = active && snapshot.sentenceIndex > 0
        center.nextTrackCommand.isEnabled = active && snapshot.sentenceIndex + 1 < (book?.sentences.count ?? 0)
    }

    private func observeAudioSession() {
        let notifications = NotificationCenter.default
        observers.append(notifications.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.audioSessionReady = false
                    self.coordinator.interrupt()
                    self.player?.pause()
                    self.refreshSnapshot()
                    self.saveCurrent()
                } else if type == AVAudioSession.InterruptionType.ended.rawValue {
                    let allowed = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                    if self.coordinator.endInterruption(shouldResume: allowed) { self.resumeCurrent() }
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
            Task { @MainActor [weak self] in self?.saveCurrent(final: true) }
        })
        observers.append(notifications.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.book != nil else { return }
                let position = self.currentPosition()
                self.audioSessionReady = false
                self.resolvedVoice = nil
                self.saveCurrent()
                self.prepare(index: self.snapshot.sentenceIndex, offset: position, autoplay: self.shouldPlay)
            }
        })
    }
}

extension PlaybackController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player, let token = self.playerTicket, self.coordinator.accepts(token) else { return }
            self.snapshot.position = player.duration
            let completion = self.coordinator.complete(token, successfully: flag)
            self.saveCurrent(positionOverride: player.duration, final: completion == .finished)
            switch completion {
            case .advance(let next):
                if let preparation = self.coordinator.continueAfterCompletion(to: next) { self.execute(preparation) }
            case .finished:
                self.player?.delegate = nil
                self.player = nil // 系统完成回调后 currentTime 可能归零，改用快照保存真实句末。
                self.playerTicket = nil
                self.snapshot.isPlaying = false
                self.snapshot.chapterProgress = self.timeline?.fraction(at: self.snapshot.sentenceIndex, offset: player.duration, duration: player.duration) ?? 1
                if !flag { self.snapshot.error = SpeechPlaybackError.invalidAudio.localizedDescription }
                self.refreshSnapshot()
            case .ignored: break
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player, let token = self.playerTicket, self.coordinator.accepts(token) else { return }
            self.fail(error ?? SpeechPlaybackError.invalidAudio)
        }
    }
}
