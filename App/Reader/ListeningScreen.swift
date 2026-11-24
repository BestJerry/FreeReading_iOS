import SwiftUI
import UIKit
import FreeReadingCore

/// 与 Android 共用信息顺序的独立听书页；返回原文不结束应用级播放会话。
@MainActor
struct ListeningScreen: View {
    let book: ReadingBook
    let repository: BookRepository
    var theme: String = "paper"
    var readingReady: Bool = true
    @ObservedObject var playback: PlaybackController
    let isLoadingSpeech: Bool
    let onMainAction: () -> Void
    let onFromReading: () -> Void
    let onPreviousChapter: () -> Void
    let onNextChapter: () -> Void
    let onLocate: () -> Void
    let onStop: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1
    @State private var voicePicker = false
    @State private var voiceSummary = "选择音色"
    @StateObject private var loading = PlaybackLoadingPresentation()
    private var preparingForPlayback: Bool { active && snapshot.isPreparing && snapshot.wantsPlayback }
    private var colors: ReadingColors { ReadingColors(theme: theme) }
    private var active: Bool { playback.snapshot.bookID == book.record.id && playback.book?.record.addedAt == book.record.addedAt }
    private var anotherBookHasAudio: Bool { snapshot.bookID != nil && !active }
    private var snapshot: PlaybackSnapshot { playback.snapshot }
    private var coverURL: URL? { book.record.coverPath.map { repository.bookDirectory(id: book.record.id).appendingPathComponent($0) } }
    private var chapterTitle: String {
        active && book.chapters.indices.contains(snapshot.chapterIndex) ? book.chapters[snapshot.chapterIndex].title : "从阅读位置开始"
    }
    private var fraction: Double {
        active && snapshot.chapterProgress.isFinite ? min(1, max(0, snapshot.chapterProgress)) : 0
    }
    private var status: String {
        if active && snapshot.isPreparing { return snapshot.wantsPlayback ? "正在准备语音…" : "已暂停，语音准备中" }
        if active { return snapshot.isPlaying ? "正在播放" : "已暂停" }
        return isLoadingSpeech ? "正在准备听书…" : "准备好开始听书"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 0) {
                    BookCoverView(title: book.record.title, url: coverURL, seed: book.record.id, prominent: true, tint: colors.accent, foreground: colors.paper)
                        .frame(width: 160, height: 160 / 0.7)
                        .shadow(color: colors.ink.opacity(0.15), radius: 16, x: 0, y: 8)
                        .padding(.bottom, 18)
                    Text(book.record.title.isEmpty ? "未命名书籍" : book.record.title)
                        .font(.system(size: 24 * textScale, weight: .medium, design: .serif))
                        .multilineTextAlignment(.center).lineLimit(2)
                        .accessibilityIdentifier("listening-book-title")
                    if !book.record.author.isEmpty {
                        Text(book.record.author).font(.system(size: 13 * textScale))
                            .foregroundStyle(colors.muted).lineLimit(1).padding(.top, 6)
                    }
                    Text(chapterTitle).font(.system(size: 13 * textScale))
                        .foregroundStyle(colors.accent).multilineTextAlignment(.center)
                        .lineLimit(2).padding(.top, 12)
                        .accessibilityIdentifier("listening-chapter-title")
                    Text(active && !snapshot.text.isEmpty ? snapshot.text : "点击播放，从阅读位置开始听书。")
                        .font(.system(size: 14 * textScale)).lineSpacing(5 * textScale)
                        .foregroundStyle(colors.muted).multilineTextAlignment(.center)
                        .lineLimit(2).frame(maxWidth: .infinity)
                        .padding(.top, 16).padding(.bottom, 18)
                        .accessibilityIdentifier("listening-current-sentence")
                    chapterProgress
                    playbackControls.padding(.vertical, 10)
                    chapterControls.padding(.bottom, 8)
                    voiceAndSpeed
                    if anotherBookHasAudio {
                        Text("开始本书听书后可选择音色")
                            .font(.system(size: 11 * textScale)).foregroundStyle(colors.muted)
                            .multilineTextAlignment(.center)
                    }
                    readingControls.padding(.top, 12)
                    if active, let message = snapshot.error {
                        Text(message).font(.system(size: 13 * textScale)).lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                            .background(colors.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                            .padding(.top, 18)
                            .accessibilityIdentifier("listening-error")
                    }
                    Button(action: onStop) {
                        Text("结束听书").font(.system(size: 12 * textScale))
                            .foregroundStyle(colors.muted).frame(minHeight: 44)
                    }
                    .disabled(!active).opacity(active ? 1 : 0.4)
                    .padding(.top, 16).padding(.bottom, 12)
                    .accessibilityIdentifier("listening-stop")
                }
                .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 12)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .background(colors.paper.ignoresSafeArea())
        .foregroundStyle(colors.ink).tint(colors.accent).buttonStyle(.plain)

        .preferredColorScheme(colors.isNight ? .dark : .light)
        .onAppear(perform: updateVoiceSummary)
        .onAppear { loading.update(isPreparing: preparingForPlayback, wantsPlayback: preparingForPlayback) }
        .onChange(of: preparingForPlayback) { _, value in loading.update(isPreparing: value, wantsPlayback: value) }
        .onDisappear { loading.cancel() }
        .onChange(of: snapshot.voiceName) { _, _ in updateVoiceSummary() }
        .sheet(isPresented: $voicePicker, onDismiss: updateVoiceSummary) {
            VoicePickerSheet(book: book, playback: playback, theme: theme)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible).presentationBackground(colors.paper)
        }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left").font(.system(size: 20))
                    Text("返回阅读").font(.system(size: 14 * textScale))
                }.frame(minHeight: 44)
            }.accessibilityIdentifier("listening-close")
            Spacer()
            Text("听书").font(.system(size: 17 * textScale, design: .serif))
                .foregroundStyle(colors.muted).padding(.trailing, 12)
        }.padding(.horizontal, 12).padding(.vertical, 4)
    }

    private var chapterProgress: some View {
        VStack(spacing: 9) {
            HStack {
                Text("本章进度").foregroundStyle(colors.muted)
                Spacer()
                Text(active ? "\(Int(fraction * 100))%" : "—").monospacedDigit()
            }.font(.system(size: 12 * textScale))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(colors.ink.opacity(0.08))
                    Capsule().fill(colors.accent).frame(width: geometry.size.width * CGFloat(fraction))
                }
            }
            .frame(height: 3)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("章节播放进度")
            .accessibilityValue(active ? "\(Int(fraction * 100))%" : "尚未开始")
            .accessibilityIdentifier("listening-chapter-progress")
            Text(status).font(.system(size: 11 * textScale)).foregroundStyle(colors.muted)
                .multilineTextAlignment(.center).padding(.top, 1)
                .accessibilityIdentifier("listening-status")
        }
    }

    private var playbackControls: some View {
        HStack {
            seekButton(forward: false)
            Spacer(minLength: 12)
            Button(action: onMainAction) {
                ZStack {
                    Circle().fill(colors.accent)
                    Image(systemName: active && snapshot.wantsPlayback ? "pause.fill" : "play.fill")
                        .font(.system(size: 34)).foregroundStyle(colors.paper)
                        .offset(x: active && snapshot.wantsPlayback ? 0 : 2)
                    if loading.isVisible {
                        ProgressView().tint(colors.paper).scaleEffect(0.65)
                            .offset(x: 24, y: -24).accessibilityHidden(true)
                    }
                }.frame(width: 80, height: 80)
            }
            .disabled(!readingReady && !active)
            .opacity(readingReady || active ? 1 : 0.3)
            .accessibilityLabel(active && snapshot.wantsPlayback ? "暂停听书" : "开始或继续听书")
            .accessibilityIdentifier("listening-main")
            Spacer(minLength: 12)
            seekButton(forward: true)
        }
    }

    private func seekButton(forward: Bool) -> some View {
        Button { playback.seek(by: forward ? 15 : -15) } label: {
            VStack(spacing: 4) {
                Image(systemName: forward ? "forward.fill" : "backward.fill").font(.system(size: 29))
                Text("15 秒").font(.system(size: 11 * textScale)).foregroundStyle(colors.muted)
            }.frame(width: 64, height: 64)
        }
        .disabled(!active).opacity(active ? 1 : 0.25)
        .accessibilityLabel(forward ? "快进15秒" : "快退15秒")
        .accessibilityIdentifier(forward ? "listening-forward" : "listening-backward")
    }

    private var chapterControls: some View {
        HStack(spacing: 12) {
            Button(action: onPreviousChapter) {
                Label("上一章", systemImage: "backward.end.fill").frame(maxWidth: .infinity)
            }
            .disabled(!active || !snapshot.canGoToPreviousChapter)
            .accessibilityIdentifier("listening-previous-chapter")
            Button(action: onNextChapter) {
                Label("下一章", systemImage: "forward.end.fill").frame(maxWidth: .infinity)
            }
            .disabled(!active || !snapshot.canGoToNextChapter)
            .accessibilityIdentifier("listening-next-chapter")
        }
        .buttonStyle(ListeningOutlineStyle(colors: colors, fontSize: 13 * textScale))
    }

    private var voiceAndSpeed: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { speed in
                    Button(String(format: "%.2g×", speed)) { playback.setSpeed(speed) }
                }
            } label: {
                Text(String(format: "%.2g× 倍速", snapshot.speed))
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(!active).opacity(active ? 1 : 0.3)
            .accessibilityLabel("播放速度").accessibilityIdentifier("listening-speed")
            Button { voicePicker = true } label: {
                Text("音色 · \(voiceSummary)").lineLimit(2)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled((!readingReady && !active) || anotherBookHasAudio)
            .opacity((readingReady || active) && !anotherBookHasAudio ? 1 : 0.3)
            .accessibilityLabel("选择朗读音色").accessibilityValue(voiceSummary)
            .accessibilityIdentifier("listening-voice-picker")
        }.font(.system(size: 13 * textScale)).foregroundStyle(colors.accent)
    }

    private var readingControls: some View {
        HStack(spacing: 10) {
            Button {
                onLocate()
                dismiss()
            } label: {
                Label("定位原文", systemImage: "scope").frame(maxWidth: .infinity)
            }
            .disabled(!active || !readingReady)
            .accessibilityLabel("定位正在朗读的原文").accessibilityIdentifier("listening-locate")
            Button(action: onFromReading) {
                Text("从阅读处听").frame(maxWidth: .infinity)
            }
            .disabled(!readingReady)
            .accessibilityLabel("从阅读位置开始听书").accessibilityIdentifier("listening-from-reading")
        }.buttonStyle(ListeningOutlineStyle(colors: colors, fontSize: 12 * textScale))
    }

    /// 系统声音枚举只在进入页面或选择变化时执行，避免播放计时快照触发反复扫描。
    private func updateVoiceSummary() {
        guard let id = playback.selectedVoiceID(language: book.record.language) else { voiceSummary = "自动选择"; return }
        voiceSummary = playback.availableVoices(language: book.record.language).first(where: { $0.id == id })?.name ?? "选择音色"
    }
}

/// 细描边胶囊按钮保持 Android 的视觉层级，并保留 iOS 的最小可点击高度。
private struct ListeningOutlineStyle: ButtonStyle {
    let colors: ReadingColors
    let fontSize: CGFloat
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize))
            .multilineTextAlignment(.center).lineLimit(2)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(colors.accent)
            .background(configuration.isPressed ? colors.ink.opacity(0.06) : .clear, in: Capsule())
            .overlay { Capsule().strokeBorder(colors.ink.opacity(0.14), lineWidth: 1) }
            .opacity(enabled ? 1 : 0.3)
            .contentShape(Capsule())
    }
}

/// 音色页保留系统可用性验证；iOS 的离线限制集中说明，避免每种声音重复同一长文。
@MainActor
private struct VoicePickerSheet: View {
    let book: ReadingBook
    @ObservedObject var playback: PlaybackController
    let theme: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1
    @State private var voices: [VoiceOption] = []
    @State private var selectedID: String?
    @State private var validatingID: String?
    @State private var validationTask: Task<Void, Never>?
    @State private var validationError: String?
    @State private var settingsHelp = false
    private var colors: ReadingColors { ReadingColors(theme: theme) }
    private var canSelect: Bool {
        playback.snapshot.bookID == nil || (playback.snapshot.bookID == book.record.id && playback.book?.record.addedAt == book.record.addedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("朗读音色").font(.system(size: 21 * textScale, weight: .medium, design: .serif))
                .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    Text("使用 iOS 系统提供的本书语言声音。")
                        .font(.system(size: 12 * textScale)).foregroundStyle(colors.muted).padding(8)
                    automaticChoice
                    ForEach(voices) { voice in voiceChoice(voice) }
                    if voices.isEmpty {
                        Text("暂无可用音色。请在系统辅助功能的语音设置中下载本书语言的声音，然后重新加载。")
                            .font(.system(size: 13 * textScale)).foregroundStyle(colors.muted)
                            .lineSpacing(5).padding(8)
                            .accessibilityIdentifier("tts-voice-empty")
                    }
                    Text("iOS 不提供可靠的逐音色离线标记。验证会独立进行无声合成，不切换当前音色；成功仅说明本次可合成。离线使用前请下载声音并断网验证。")
                        .font(.system(size: 12 * textScale)).foregroundStyle(colors.muted)
                        .lineSpacing(5).padding(8)
                    Button("系统语音设置说明") { settingsHelp = true }
                        .font(.system(size: 13 * textScale)).foregroundStyle(colors.accent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("tts-voice-settings")
                }
            }
            HStack(spacing: 8) {
                Button("重新加载", action: reload).disabled(validatingID != nil)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("tts-voice-retry")
                Button("完成") { dismiss() }.frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("tts-voice-done")
            }.font(.system(size: 13 * textScale)).foregroundStyle(colors.accent).padding(.top, 8)
        }
        .padding(16).frame(maxWidth: 520).frame(maxWidth: .infinity)
        .background(colors.paper.ignoresSafeArea()).foregroundStyle(colors.ink)
        .tint(colors.accent).buttonStyle(.plain)
        .preferredColorScheme(colors.isNight ? .dark : .light)

        .onAppear(perform: reload)
        .onChange(of: scenePhase) { _, phase in if phase == .active { reload() } }
        .onDisappear { validationTask?.cancel() }
        .alert("音色验证未完成", isPresented: Binding(get: { validationError != nil }, set: { if !$0 { validationError = nil } })) {
            Button("知道了", role: .cancel) { validationError = nil }
        } message: { Text(validationError ?? "") }
        .alert("系统语音设置", isPresented: $settingsHelp) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text("请在 iOS“设置”的辅助功能语音选项中下载所需语言的声音，返回 FreeReading 后点击“重新加载”。应用无法直接打开系统语音下载页面。")
        }
    }

    private var automaticChoice: some View {
        Button {
            guard canSelect else { return }
            playback.selectVoice(id: nil, language: book.record.language); dismiss()
        } label: {
            HStack(spacing: 12) {
                selectionMark(selectedID == nil)
                VStack(alignment: .leading, spacing: 4) {
                    Text("自动选择").font(.system(size: 14 * textScale))
                    Text("根据本书语言选择系统声音")
                        .font(.system(size: 12 * textScale)).foregroundStyle(colors.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 12).contentShape(Rectangle())
        }
        .disabled(!canSelect).opacity(canSelect ? 1 : 0.4)
        .accessibilityValue(selectedID == nil ? "已选择" : "")
        .accessibilityIdentifier("tts-voice-automatic")
    }

    private func voiceChoice(_ voice: VoiceOption) -> some View {
        HStack(spacing: 8) {
            Button {
                guard canSelect else { return }
                playback.selectVoice(id: voice.id, language: book.record.language); dismiss()
            } label: {
                HStack(spacing: 12) {
                    selectionMark(selectedID == voice.id)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(voice.name).font(.system(size: 14 * textScale))
                        Text((Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language) + " · " + voice.availabilityText)
                            .font(.system(size: 12 * textScale)).foregroundStyle(colors.muted)
                    }
                    Spacer(minLength: 0)
                }.padding(.vertical, 10).contentShape(Rectangle())
            }
            .disabled(!canSelect).opacity(canSelect ? 1 : 0.4)
            .accessibilityValue(selectedID == voice.id ? "已选择" : "")
            .accessibilityIdentifier("tts-voice-\(voice.id)")
            Button { validate(voice) } label: {
                Group {
                    if validatingID == voice.id { ProgressView().controlSize(.small) }
                    else { Text("验证").font(.system(size: 12 * textScale)) }
                }.frame(minWidth: 44, minHeight: 44)
            }
            .disabled(validatingID != nil).foregroundStyle(colors.accent)
            .accessibilityLabel("验证\(voice.name)能否合成")
        }.padding(.horizontal, 8)
    }

    private func selectionMark(_ selected: Bool) -> some View {
        ZStack {
            Circle().strokeBorder(selected ? colors.accent : colors.ink.opacity(0.5), lineWidth: 1.5)
            if selected { Circle().fill(colors.accent).padding(5) }
        }.frame(width: 22, height: 22).accessibilityHidden(true)
    }

    private func reload() {
        validationTask?.cancel(); validationTask = nil; validatingID = nil
        var seen = Set<String>()
        voices = playback.refreshVoices(language: book.record.language).filter { seen.insert($0.id).inserted }
        selectedID = playback.selectedVoiceID(language: book.record.language)
    }

    private func validate(_ voice: VoiceOption) {
        validationTask?.cancel(); validatingID = voice.id
        validationTask = Task { @MainActor in
            do { try await playback.validateVoice(id: voice.id, language: book.record.language) }
            catch { if !Task.isCancelled { validationError = error.localizedDescription } }
            guard !Task.isCancelled else { return }
            voices = playback.availableVoices(language: book.record.language)
            validatingID = nil; validationTask = nil
        }
    }
}
