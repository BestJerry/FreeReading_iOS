# 模块接口约定

Core 模型位于 Sources/FreeReadingCore/Models.swift，由主代理持有。

- BookRepository actor: init(root: URL? = nil) throws; nonisolated let root: URL; books() throws -> [BookRecord]; importEPUB(from: URL, progress: @Sendable (ImportProgress) -> Void) throws -> SpeechBook; loadBook(id: String) throws -> SpeechBook; readingProgress(bookID: String) throws -> ReadingProgress?; saveProgress(_ progress: ReadingProgress) throws; removeBook(id: String) throws; nonisolated contentURL(bookID: String, href: String) throws -> URL; nonisolated bookDirectory(id: String) -> URL.
- 提取目录 books/<hash>/content；JSON索引由数据层保存。HTML中的可朗读原段落须注入 data-fr-section="<sectionID>"，保留原id和样式。SpeechSentence.range 是对应 element.textContent 的UTF-16范围；必须保证JS与Swift文本空白一致。
- @MainActor PlaybackController: ObservableObject，init(repository: BookRepository)，@Published private(set) snapshot: PlaybackSnapshot，private(set) book: SpeechBook?；start(book: SpeechBook, sentenceIndex: Int, offset: Double = 0); toggle(); pause(); stop(); seek(by: Double); previousChapter(); nextChapter(); setSpeed(_ speed: Float); availableVoices(language: String) -> [VoiceOption]; selectedVoiceID(language: String) -> String?; selectVoice(id: String?, language: String)。控制方法同步入口，内部管理Task和取消。progress写盘由音频层负责。
- PlaybackSnapshot字段：bookID:String?，sentenceIndex:Int，chapterIndex:Int，text:String，isPlaying:Bool，wantsPlayback:Bool（准备期间的用户播放意图），isPreparing:Bool，position:Double（秒），duration:Double，speed:Float，chapterProgress:Double，error:String?，voiceName:String，canGoToPreviousChapter:Bool，canGoToNextChapter:Bool。VoiceOption: Identifiable（id/name/language都是String）。默认值由audio层提供。
- ReaderScreen(book: SpeechBook, repository: BookRepository, playback: PlaybackController) SwiftUI入口，由reader层实现。导航关闭不会停止听书。播放器UI由reader层实现，使用上述API。App/Library/与AppStore由主代理持有。
- iOS17+；Swift tools5.10，Core可在macOS运行单测。库版本固定 ZIPFoundation0.9.20 / SwiftSoup2.14.4。只根代理运行swift test/xcodebuild，避免构建竞争。各模块须中文类/关键方法注释。

- Core saveProgress(_:expectedAddedAt:Date?=nil) 可按导入批次拒绝迟到写入；音频与阅读必须传book.record.addedAt。音频removeCachedAudio(bookID:)用于书架移除后的CAF清理。
