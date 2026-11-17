# 模块接口约定

应用层使用 SwiftUI、WebKit、AVFoundation 和 MediaPlayer；Core 可在 macOS 独立测试，主要使用 Foundation，缓冲提示模型使用 Combine。类职责和关键方法使用中文注释。

## 书库和开书

- `prepareReadingBook(id:) async throws -> ReadingBookBootstrap` 返回轻量目录、章节权重、阅读进度及可选内存听书索引。它等待同一 `addedAt` 批次登记的最终保存，不为首屏解码整个听书索引。
- `loadSpeechBook(id:) async throws -> SpeechBook` 合并同一本书的并发解码；不等待最终保存，避免最终保存为映射句子而请求索引时自锁。旧 `loadBook(id:)` 兼容完整加载。
- `registerReadingSave(bookID:expectedAddedAt:task:)` 同步登记异步保存，任务完成后按 token 回收。阅读退出、暂停和结束听书等最终保存应登记。
- `saveProgress(_:expectedAddedAt:)` 按导入批次、有效范围及时间顺序校验，写盘失败仍在内存保留最新合法位置，后续访问重试。
- 目录修改通过可取消的 gate 串行化；导入解包与索引工作离开 repository actor，不阻塞现有书籍的进度保存。
- v2 由 `book.json`、小型 `reading.json`、`index.json` 计数头、`sections.jsonl` 和 `sentences.jsonl` 组成；旧 v1 JSON 流式兼容并延迟迁移。数据原子提交前取消不会发布半本书，旧库迁移写盘失败仍可继续阅读。
- `BookRecord.readingDirection` 是可选字段，旧记录默认 LTR；`chapterWeights` 是对应章节的 UTF-16 文本长度。

## 导入与分享

`ImportCoordinator` 是实际供书架使用的 MainActor 状态协调器。新请求取代旧请求，请求 UUID 防止迟到进度、结果、错误触发导航。安全作用域由任务和失败重试会话共同持有。取消后的来源清理必须等 worker 退出。

`ShareInbox` 只传递原文件：扩展在临时目录完成有界复制和 manifest 后原子发布，主应用领取到 processing 后复用普通导入；硬退出可恢复，成功或用户取消后清理。损坏项目移到 rejected，不阻塞其他书籍。主应用和扩展需配置相同 App Group。扩展不调用不受支持的主应用唤起方式。

## 原文与播放

- `ReaderScreen(bootstrap:repository:playback:openPlayer:)` 为首选入口；旧 `book:SpeechBook` 初始化兼容。
- HTML 注入 `data-fr-section`，不改写书内原 ID。`SpeechSentence.range` 与浏览器 TextNode 的 UTF-16 文本坐标一致。高亮由真实 DOM Range 产生，保留内联排版。
- `ReaderProgressPolicy` 提供实际接入的游标保存、音频恢复保护与全书权重规则。朗读游标和视觉位置分别处理；停止听书后，非用户阅读导航不会把句内音频偏移归零。
- `PlaybackCoordinator` 实际裁决异步代次、暂停、seek 累加、换声比例、中断和旧回调。AVAudioPlayer 与合成器副作用留在 App 层。
- 自然换句使用 continuous 交接，保留同书同音色的预取并复用已准备的下一播放器；显式跳转、换声和停止才取消。`SpeechPrefetchWindow` 储备约 12 秒、最多 12 句。`SpeechPreparationQueue` 合并同句请求并管理前台优先级与取消。
- `PlaybackLoadingPresentation` 仅在准备且有播放意图持续 300ms 后显示缓冲提示，暂停、完成或离页立即取消；中央播放／暂停操作保持可见。
- `PlaybackTimeline` 根据实际音频长度执行跨句 ±15 秒；章节百分比按章节文本权重与当前句音频位置推进。
- App 相邻章按钮从章首播放；系统远程上一项／下一项按句切换并保留暂停。
- 音色刷新重新枚举系统目录；独立无声合成校验不抢占播放。验证成功只代表当前可合成，不代表系统保证离线。iOS 没有可靠的逐音色离线标记。

## 验证范围

`swift test --jobs 2` 覆盖 Core 实际协调规则、文件 IO、100k 句流式索引，以及加载真实 `.xhtml` 的 macOS WebKit 分页、高亮和 RTL 回归。`Tests/Scripts/test_generate_project.py` 验证工程再生成不丢签名、共享容器或数组设置。`Scripts/check.sh` 再执行完整 iOS 无签名编译，包含分享扩展。

这些检查不能代替 iPhone 上系统 TTS 音频、锁屏、蓝牙路由及第三方分享提供方的设备专项验收。
