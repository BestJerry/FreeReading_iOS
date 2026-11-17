import AVFoundation
import CryptoKit
import Foundation

/// 按句生成 CAF 并复用缓存；调用方串行调度合成，取消旧请求后才可以开始新请求。
@MainActor
final class SpeechAudioCache {
    private let root: URL
    private var active: SpeechSynthesisJob?
    private var protectedURLs = Set<URL>()
    private let capacity = 256 * 1_024 * 1_024

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        root = base.appendingPathComponent("FreeReading/Speech", isDirectory: true)
    }

    /// 队列仍会使用的音频不能被 LRU 回收。
    func protect(_ urls: [URL]) { protectedURLs = Set(urls) }

    /// 只列出系统提供的同语言声音，不请求用户的个人声音授权。
    func voices(language: String) -> [AVSpeechSynthesisVoice] {
        let key = Self.languageKey(language)
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { Self.languageKey($0.language) == key && !$0.voiceTraits.contains(.isPersonalVoice) }
            .filter { AVSpeechSynthesisVoice(identifier: $0.identifier) != nil }
            .sorted {
                let leftExact = $0.language.lowercased() == language.replacingOccurrences(of: "_", with: "-").lowercased()
                let rightExact = $1.language.lowercased() == language.replacingOccurrences(of: "_", with: "-").lowercased()
                if leftExact != rightExact { return leftExact }
                if $0.quality.rawValue != $1.quality.rawValue { return $0.quality.rawValue > $1.quality.rawValue }
                return $0.identifier < $1.identifier
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

    /// 缓存键隔离系统版本、声音及文本；倍速在播放器端处理，合成始终使用系统默认语速。
    func ensure(bookID: String, text: String, voice: AVSpeechSynthesisVoice) async throws -> CachedSpeechClip {
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SpeechPlaybackError.emptyText }
        let voiceKey = "\(ProcessInfo.processInfo.operatingSystemVersionString)|\(voice.identifier)|rate=default|\(text)"
        let key = SHA256.hash(data: Data(voiceKey.utf8)).map { String(format: "%02x", $0) }.joined()
        // bookID 在书库中由 SHA-256 生成，这里仍使用哈希作为目录名，避免任意路径参与拼接。
        let safeBookID = SHA256.hash(data: Data(bookID.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent(safeBookID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 用户首次解锁后，锁屏中的后台音频仍需读取和预取该目录。
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        let final = directory.appendingPathComponent(key).appendingPathExtension("caf")
        if let clip = try? readClip(final) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: final.path)
            return clip
        }
        try? FileManager.default.removeItem(at: final)
        // 每代操作都会先 cancel；若调用者违反串行约定，不让两个合成器竞争同一队列。
        guard active == nil else { throw SpeechPlaybackError.synthesisFailed }
        let temporary = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("partial.caf")
        let job = SpeechSynthesisJob(url: temporary)
        active = job
        defer {
            if active === job { active = nil }
            try? FileManager.default.removeItem(at: temporary)
        }
        do {
            try await job.run(text: text, voice: voice)
            try Task.checkCancellation()
            _ = try readClip(temporary)
            try FileManager.default.moveItem(at: temporary, to: final)
            let clip = try readClip(final)
            try trim(keeping: final)
            return clip
        } catch {
            job.cancel()
            throw error
        }
    }

    /// 旧合成器独立持有自己的回调，停止它不会中断随后创建的新合成器。
    func cancel() {
        let old = active
        active = nil
        old?.cancel()
    }

    /// 移除书籍时回收对应缓存；失败的文件仍可由后续容量回收再次处理。
    func remove(bookID: String) {
        let safeID = SHA256.hash(data: Data(bookID.utf8)).map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.removeItem(at: root.appendingPathComponent(safeID, isDirectory: true))
    }

    private func readClip(_ url: URL) throws -> CachedSpeechClip {
        let audio = try AVAudioFile(forReading: url)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        guard duration.isFinite, duration > 0.005, audio.length > 0 else { throw SpeechPlaybackError.invalidAudio }
        return CachedSpeechClip(url: url, duration: duration)
    }

    /// 按最近使用时间回收未保护的音频；删除失败时保留实际大小判断，不承诺成功回收。
    private func trim(keeping keep: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        var files: [(URL, Int, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "caf" {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            files.append((url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
        }
        var size = files.reduce(0) { $0 + $1.1 }
        for (url, bytes, _) in files.sorted(by: { $0.2 < $1.2 }) where size > capacity && url != keep && !protectedURLs.contains(url) {
            do { try FileManager.default.removeItem(at: url); size -= bytes } catch { continue }
        }
        if size > capacity {
            try? FileManager.default.removeItem(at: keep)
            throw SpeechPlaybackError.cacheFull
        }
    }

    private func preferenceKey(_ language: String) -> String { "FreeReading.voice.\(Self.languageKey(language))" }

    static func languageKey(_ language: String) -> String {
        let base = language.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init)?.lowercased() ?? ""
        return ["zho": "zh", "chi": "zh", "eng": "en", "fra": "fr", "fre": "fr", "deu": "de", "ger": "de", "jpn": "ja"][base] ?? base
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
