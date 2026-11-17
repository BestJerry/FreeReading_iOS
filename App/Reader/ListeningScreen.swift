import SwiftUI
import UIKit
import ImageIO
import FreeReadingCore

/// 独立听书面板；关闭面板仅返回原文，后台播放器继续持有播放会话。
@MainActor
struct ListeningScreen: View {
    let book: SpeechBook
    let repository: BookRepository
    @ObservedObject var playback: PlaybackController
    @Binding var followAudio: Bool
    let detached: Bool
    let onMainAction: () -> Void
    let onFromReading: () -> Void
    let onPreviousChapter: () -> Void
    let onNextChapter: () -> Void
    let onResumeFollow: () -> Void
    let onStop: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var voicePicker = false
    private var active: Bool { playback.snapshot.bookID == book.record.id }
    private var snapshot: PlaybackSnapshot { playback.snapshot }
    private var coverURL: URL? { book.record.coverPath.map { repository.bookDirectory(id: book.record.id).appendingPathComponent($0) } }
    private var chapterTitle: String {
        active && book.chapters.indices.contains(snapshot.chapterIndex) ? book.chapters[snapshot.chapterIndex].title : "从阅读位置开始"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    ReaderBookArtwork(title: book.record.title, url: coverURL)
                        .frame(width: 145, height: 204)
                        .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 10)
                        .padding(.top, 16)
                    VStack(spacing: 8) {
                        Text(book.record.title).font(.system(.title2, design: .serif).weight(.semibold)).multilineTextAlignment(.center)
                        Text(book.record.author.isEmpty ? "本地 EPUB" : book.record.author).font(.subheadline).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(chapterTitle).font(.subheadline.weight(.medium)).lineLimit(2)
                            Spacer()
                            Text(active ? snapshot.chapterProgress : 0, format: .percent.precision(.fractionLength(0))).font(.caption).monospacedDigit()
                        }
                        ProgressView(value: active && snapshot.chapterProgress.isFinite ? min(1, max(0, snapshot.chapterProgress)) : 0)
                            .tint(ReaderPalette.forest)
                            .accessibilityLabel("章节正文进度")
                        Text(active && !snapshot.text.isEmpty ? snapshot.text : "点击播放，从上次听到的位置继续；也可从当前阅读处开始。")
                            .font(.body).foregroundStyle(.secondary)
                            .lineLimit(5).frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
                        if active && snapshot.isPreparing { Label("正在准备当前句", systemImage: "waveform").font(.caption).foregroundStyle(.secondary) }
                    }
                    HStack(spacing: 30) {
                        Button { if active { playback.seek(by: -15) } } label: { Image(systemName: "gobackward.15").font(.system(size: 31)).frame(width: 48, height: 48) }
                            .disabled(!active).accessibilityLabel("快退15秒")
                        Button(action: onMainAction) {
                            ZStack {
                                Circle().fill(ReaderPalette.forest).frame(width: 78, height: 78)
                                Image(systemName: active && snapshot.wantsPlayback ? "pause.fill" : "play.fill")
                                    .font(.system(size: 28)).foregroundStyle(.white)
                            }
                        }.accessibilityLabel(active && snapshot.wantsPlayback ? "暂停" : "播放")
                        Button { if active { playback.seek(by: 15) } } label: { Image(systemName: "goforward.15").font(.system(size: 31)).frame(width: 48, height: 48) }
                            .disabled(!active).accessibilityLabel("快进15秒")
                    }.buttonStyle(.plain)
                    HStack(spacing: 16) {
                        Button(action: onPreviousChapter) { Label("上一章", systemImage: "backward.end.fill").frame(maxWidth: .infinity) }
                            .disabled(!active || !snapshot.canGoToPreviousChapter)
                        Button(action: onNextChapter) { Label("下一章", systemImage: "forward.end.fill").frame(maxWidth: .infinity) }
                            .disabled(!active || !snapshot.canGoToNextChapter)
                    }.buttonStyle(.bordered).controlSize(.large)
                    HStack {
                        Menu {
                            ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { speed in
                                Button(String(format: "%.2g×", speed)) { playback.setSpeed(speed) }
                            }
                        } label: { Label(String(format: "%.2g×", snapshot.speed), systemImage: "speedometer") }
                        Spacer()
                        Button { voicePicker = true } label: { Label("音色", systemImage: "person.wave.2") }
                            .disabled(snapshot.bookID != nil && !active)
                        Spacer()
                        Button(action: onFromReading) { Label("从阅读处听", systemImage: "text.book.closed") }
                    }.font(.subheadline).buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("原文随朗读自动翻页", isOn: $followAudio).tint(ReaderPalette.forest)
                        if active && followAudio && detached {
                            Button(action: onResumeFollow) { Label("继续跟随当前朗读句", systemImage: "location") }
                        }
                        Text("章节进度表示正文位置；当前句准备好后即可播放，无须等待整章。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if active, let message = snapshot.error {
                        Label(message, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if active { Button("结束听书", role: .destructive, action: onStop).padding(.bottom, 8) }
                }.padding(.horizontal, 28).padding(.bottom, 24)
            }
            .background(ReaderPalette.paper)
            .foregroundStyle(ReaderPalette.ink)
            .navigationTitle("听书").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("返回阅读") { dismiss() } } }
            .sheet(isPresented: $voicePicker) {
                VoicePickerSheet(book: book, playback: playback)
                    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
        }.tint(ReaderPalette.forest)
    }
}

/// 音色选择仅持有本弹层状态，异步播放快照变化不会重置外层听书页面。
@MainActor
private struct VoicePickerSheet: View {
    let book: SpeechBook
    @ObservedObject var playback: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var voices: [VoiceOption] = []
    private var canSelect: Bool { playback.snapshot.bookID == nil || playback.snapshot.bookID == book.record.id }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    guard canSelect else { return }
                    playback.selectVoice(id: nil, language: book.record.language); dismiss()
                } label: {
                    HStack { Text("自动选择"); Spacer(); if playback.selectedVoiceID(language: book.record.language) == nil { Image(systemName: "checkmark") } }
                }.disabled(!canSelect)
                Section("系统可用音色") {
                    ForEach(voices) { voice in
                        Button {
                            guard canSelect else { return }
                            playback.selectVoice(id: voice.id, language: book.record.language); dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) { Text(voice.name); Text(voice.language).font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                if playback.selectedVoiceID(language: book.record.language) == voice.id { Image(systemName: "checkmark") }
                            }
                        }.disabled(!canSelect)
                    }
                    if voices.isEmpty { Text("系统没有提供本书语言的可用声音。").foregroundStyle(.secondary) }
                }
                Section {
                    Button("重新加载音色") { reload() }
                } footer: {
                    Text("声音由 iOS 系统提供。可在系统辅助功能的语音设置中下载更多声音，返回后重新加载。下载状态及离线能力由系统管理。")
                }
            }
            .navigationTitle("选择音色").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .onAppear(perform: reload)
        .onChange(of: scenePhase) { _, phase in if phase == .active { reload() } }
        .tint(ReaderPalette.forest)
    }

    private func reload() {
        var seen = Set<String>()
        voices = playback.availableVoices(language: book.record.language).filter { seen.insert($0.id).inserted }
    }
}

/// 缩略图按展示尺寸解码，长书的大封面不在主线程完整展开。
@MainActor
private struct ReaderBookArtwork: View {
    let title: String
    let url: URL?
    @State private var image: UIImage?
    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8).fill(ReaderPalette.forest.gradient)
            if let image {
                Image(uiImage: image).resizable().scaledToFill().clipped()
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text("FREE / READING").font(.system(size: 8)).tracking(1.5).opacity(0.65)
                    Text(title).font(.system(.title3, design: .serif)).lineLimit(5)
                    Spacer()
                    Image(systemName: "book").font(.title2).opacity(0.7)
                }.foregroundStyle(.white).padding(18)
            }
            Rectangle().fill(.black.opacity(0.12)).frame(width: 5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: url) {
            let target = url
            image = await Task.detached(priority: .utility) {
                guard let target, let source = CGImageSourceCreateWithURL(target as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 600,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) else { return nil as UIImage? }
                return UIImage(cgImage: image)
            }.value
        }
        .accessibilityLabel("书籍封面")
    }
}
