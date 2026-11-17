import AVFoundation
import CryptoKit
import Foundation
import FreeReadingCore

/// 按句生成 CAF 并复用缓存；播放与预取共用串行单飞队列，同一句的在途结果只合成一次。
@MainActor
final class SpeechAudioCache {
    private let root: URL
    private let preparation = SpeechPreparationQueue<String, CachedSpeechClip>()
    private var protectedURLs = Set<URL>()
    private var validatedVoices = Set<String>()
    private var catalogGeneration: UInt64 = 0
    private let capacity = 256 * 1_024 * 1_024
    private var knownBytes: Int?
    private var cacheMutation: UInt64 = 0

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        root = base.appendingPathComponent("FreeReading/Speech", isDirectory: true)
    }

    /// 队列仍会使用的音频不能被 LRU 回收。
    func protect(_ urls: [URL]) { protectedURLs = Set(urls) }

    /// 只列出系统提供的同语言声音，不请求用户的个人声音授权。
    func voices(language: String) -> [AVSpeechSynthesisVoice] {
        var seen = Set<String>()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { SpeechLanguagePolicy.matchRank(candidate: $0.language, requested: language) >= 0 && !$0.voiceTraits.contains(.isPersonalVoice) }
            .filter { AVSpeechSynthesisVoice(identifier: $0.identifier) != nil }
            .sorted {
                let left = SpeechLanguagePolicy.matchRank(candidate: $0.language, requested: language)
                let right = SpeechLanguagePolicy.matchRank(candidate: $1.language, requested: language)
                if left != right { return left > right }
                if $0.quality.rawValue != $1.quality.rawValue { return $0.quality.rawValue > $1.quality.rawValue }
                return $0.identifier < $1.identifier
            }
            .filter { seen.insert($0.identifier).inserted }
    }

    /// 重新从系统取目录；验证结果只在当前进程有效，用户刷新后必须重新合成校验。
    func refreshVoices(language: String) -> [AVSpeechSynthesisVoice] {
        catalogGeneration &+= 1
        validatedVoices.removeAll()
        _ = selectedID(language: language)
        return voices(language: language)
    }

    func isValidated(voiceID: String) -> Bool { validatedVoices.contains(voiceID) }

    /// 使用独立且不出声的写文件任务验证当前声音，既不命中旧缓存，也不取消听书队列。
    /// iOS 没有逐声音的网络依赖标志，成功只代表此刻能合成，不标记“离线已验证”。
    func validateVoice(id: String, language: String) async throws {
        guard let voice = voices(language: language).first(where: { $0.identifier == id }) else { throw SpeechPlaybackError.noVoice(language) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let temporary = root.appendingPathComponent(UUID().uuidString).appendingPathExtension("validation.partial.caf")
        let job = SpeechSynthesisJob(url: temporary)
        let generation = catalogGeneration
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let phrase = Self.languageKey(language) == "zh" ? "阅读，让世界更辽阔。" : "Free Reading."
            try await job.run(text: phrase, voice: voice)
            try Task.checkCancellation()
            _ = try readClip(temporary)
            guard generation == catalogGeneration else { throw CancellationError() }
            validatedVoices.insert(id)
        } catch {
            job.cancel()
            if generation == catalogGeneration { validatedVoices.remove(id) }
            throw error
        }
    }

    func selectedID(language: String) -> String? {
        let key = preferenceKey(language)
        guard let selected = UserDefaults.standard.string(forKey: key) else { return nil }
        guard voices(language: language).contains(where: { $0.identifier == selected }) else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        return selected
    }

    /// 选择按基础语言保存；无效或移除的声音自动回退，nil 恢复自动选择。
    func select(id: String?, language: String) {
        if let id, voices(language: language).contains(where: { $0.identifier == id }) {
            UserDefaults.standard.set(id, forKey: preferenceKey(language))
        } else {
            UserDefaults.standard.removeObject(forKey: preferenceKey(language))
        }
    }

    func effectiveVoice(language: String) throws -> AVSpeechSynthesisVoice {
        let available = voices(language: language)
        if let selected = selectedID(language: language), let voice = available.first(where: { $0.identifier == selected }) { return voice }
        guard let voice = available.first else { throw SpeechPlaybackError.noVoice(language) }
        return voice
    }

    /// 已完成的 CAF 可同步接续播放，不先进入“准备中”；未完成的预取由 ensure 接管。
    func cachedClip(bookID: String, text: String, voice: AVSpeechSynthesisVoice) -> CachedSpeechClip? {
        let final = clipURL(bookID: bookID, text: text, voice: voice)
        guard let clip = try? readClip(final) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: final.path)
        return clip
    }

    /// 缓存键隔离系统版本、声音及文本；倍速在播放器端处理，合成始终使用系统默认语速。
    func ensure(bookID: String, text: String, voice: AVSpeechSynthesisVoice,
                priority: SpeechPreparationPriority = .playback) async throws -> CachedSpeechClip {
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SpeechPlaybackError.emptyText }
        if let clip = cachedClip(bookID: bookID, text: text, voice: voice) { return clip }
        let final = clipURL(bookID: bookID, text: text, voice: voice)
        return try await preparation.value(for: final.path, priority: priority) { [self] in
            // 请求排队期间文件可能已由上一代完成；此时同样无需再启动合成器。
            if let clip = cachedClip(bookID: bookID, text: text, voice: voice) { return clip }
            return try await synthesize(text: text, voice: voice, final: final)
        }
    }

    private func clipURL(bookID: String, text: String, voice: AVSpeechSynthesisVoice) -> URL {
        let voiceKey = "\(ProcessInfo.processInfo.operatingSystemVersionString)|\(voice.identifier)|rate=default|\(text)"
        let key = SHA256.hash(data: Data(voiceKey.utf8)).map { String(format: "%02x", $0) }.joined()
        // bookID 在书库中由 SHA-256 生成，这里仍使用哈希作为目录名，避免任意路径参与拼接。
        let safeBookID = SHA256.hash(data: Data(bookID.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(safeBookID, isDirectory: true).appendingPathComponent(key).appendingPathExtension("caf")
    }

    private func synthesize(text: String, voice: AVSpeechSynthesisVoice, final: URL) async throws -> CachedSpeechClip {
        try Task.checkCancellation()
        let directory = final.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 用户首次解锁后，锁屏中的后台音频仍需读取和预取该目录。
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        if FileManager.default.fileExists(atPath: final.path) {
            try? FileManager.default.removeItem(at: final)
            knownBytes = nil; cacheMutation &+= 1
        }
        let temporary = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("partial.caf")
        let job = SpeechSynthesisJob(url: temporary)
        defer {
            try? FileManager.default.removeItem(at: temporary)
        }
        do {
            try await job.run(text: text, voice: voice)
            try Task.checkCancellation()
            let clip = try readClip(temporary)
            let bytes = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            try await trim(keeping: final, adding: bytes)
            try Task.checkCancellation()
            // 先完成容量核对再发布最终路径，cachedClip 不会把尚未回收完成的文件交给播放器。
            try FileManager.default.moveItem(at: temporary, to: final)
            validatedVoices.insert(voice.identifier)
            return CachedSpeechClip(url: final, duration: clip.duration)
        } catch {
            knownBytes = nil
            job.cancel()
            throw error
        }
    }

    /// 明确改变播放目标时取消队列；自然换句应复用预取，不调用此方法。
    func cancel() {
        preparation.cancelAll()
    }

    /// 移除书籍时回收对应缓存；失败的文件仍可由后续容量回收再次处理。
    func remove(bookID: String) {
        let safeID = SHA256.hash(data: Data(bookID.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent(safeID, isDirectory: true)
        preparation.cancel { $0.hasPrefix(directory.path + "/") }
        try? FileManager.default.removeItem(at: directory)
        knownBytes = nil; cacheMutation &+= 1
    }

    private func readClip(_ url: URL) throws -> CachedSpeechClip {
        let audio = try AVAudioFile(forReading: url)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        guard duration.isFinite, duration > 0.005, audio.length > 0 else { throw SpeechPlaybackError.invalidAudio }
        return CachedSpeechClip(url: url, duration: duration)
    }

    private struct CacheFile: Sendable { let url: URL; let bytes: Int; let modified: Date }

    /// 预算内只累计新增文件大小；首次和超预算时离开主线程扫描，避免每句扫描并排序整个缓存。
    private func trim(keeping keep: URL, adding bytes: Int) async throws {
        if let knownBytes {
            let addition = knownBytes.addingReportingOverflow(bytes)
            self.knownBytes = addition.overflow ? nil : addition.partialValue
            if !addition.overflow, addition.partialValue <= capacity { return }
        }
        let directory = root
        var revision: UInt64
        var entries: [CacheFile]
        repeat {
            revision = cacheMutation
            let scan = Task.detached(priority: .utility) { try Self.cacheFiles(in: directory) }
            entries = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
            try Task.checkCancellation()
            // 删除另一本书会改变目录；重新统计，不能把刚删掉的文件算进预算或错误地回收其他书。
        } while revision != cacheMutation
        // 新文件仍是 partial，此时扫描不包含它，预算应预留本次将提交的字节。
        var size = entries.reduce(bytes) { $0 + $1.bytes }
        if size > capacity {
            for file in entries.sorted(by: { $0.modified < $1.modified })
                where size > capacity && file.url != keep && !protectedURLs.contains(file.url) {
                do { try FileManager.default.removeItem(at: file.url); size -= file.bytes } catch { continue }
            }
        }
        knownBytes = size
        if size > capacity {
            knownBytes = nil
            throw SpeechPlaybackError.cacheFull
        }
    }

    private nonisolated static func cacheFiles(in root: URL) throws -> [CacheFile] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var entries: [CacheFile] = []
        for case let url as URL in enumerator where url.pathExtension == "caf" && !url.lastPathComponent.hasSuffix(".partial.caf") {
            try Task.checkCancellation()
            // 另一本书被移除时允许跳过刚消失的文件。
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            entries.append(CacheFile(url: url, bytes: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast))
        }
        return entries
    }

    private func preferenceKey(_ language: String) -> String { "FreeReading.voice.\(Self.languageKey(language))" }

    static func languageKey(_ language: String) -> String {
        SpeechLanguagePolicy.languageKey(language)
    }
}

/// 每个请求拥有独立合成器和受锁保护的写入器，任一结束路径只恢复 continuation 一次。
private final class SpeechSynthesisJob: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let url: URL
    private let lock = NSLock()
    private var output: AVAudioFile?
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    init(url: URL) { self.url = url }

    @MainActor
    func run(text: String, voice: AVSpeechSynthesisVoice) async throws {
        let timeout = Task<Void, Never> { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.cancel(error: SpeechPlaybackError.timedOut)
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler(operation: {
            try await self.synthesize(text: text, voice: voice)
        }, onCancel: { [weak self] in
            Task<Void, Never> { @MainActor [weak self] in self?.cancel() }
        })
    }

    /// 显式声明 continuation 和系统回调类型，避免新版 Swift 对两个 write 重载的推断歧义。
    @MainActor
    private func synthesize(text: String, voice: AVSpeechSynthesisVoice) async throws {
        try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
            lock.lock()
            if finished { lock.unlock(); pending.resume(throwing: CancellationError()); return }
            continuation = pending
            lock.unlock()
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            synthesizer.delegate = self
            synthesizer.usesApplicationAudioSession = true
            let callback: AVSpeechSynthesizer.BufferCallback = { [weak self] (buffer: AVAudioBuffer) in
                self?.receive(buffer)
            }
            synthesizer.write(utterance, toBufferCallback: callback)
        }
    }

    @MainActor
    func cancel(error: Error = CancellationError()) {
        complete(.failure(error))
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func receive(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { complete(.failure(SpeechPlaybackError.invalidAudio)); return }
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if pcm.frameLength == 0 {
            lock.unlock()
            complete(.success(()))
            return
        }
        do {
            if output == nil { output = try AVAudioFile(forWriting: url, settings: pcm.format.settings, commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved) }
            try output?.write(from: pcm)
            lock.unlock()
        } catch {
            lock.unlock()
            complete(.failure(error))
        }
    }

    private func complete(_ result: Result<Void, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        output = nil // 关闭文件并写入最终音频长度后才交给读取方。
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        complete(.failure(CancellationError()))
    }
}
