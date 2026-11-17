# FreeReading iOS

FreeReading 的 iOS 原生版本，使用 **SwiftUI、WebKit 和系统 TTS**，对齐 [Android 版](https://github.com/BestJerry/FreeReading_android) 的本地 EPUB 阅读与听书体验。

项目仓库：[BestJerry/FreeReading_iOS](https://github.com/BestJerry/FreeReading_iOS)。当前源码版本 **0.1.0**，支持 **iOS 17 及以上**的 iPhone 和 iPad。

## 功能

| 功能 | 当前实现 |
| --- | --- |
| EPUB 书架 | 从“文件”导入，保留书籍、封面、目录和进度；按文件哈希去重 |
| 系统打开 | 注册 EPUB 文档类型，通过系统文档打开入口导入后进入阅读 |
| 导入进度 | 分别显示复制、检查、整理正文、保存阶段；未知总量使用等待指示 |
| 纯净阅读 | 保留 EPUB 原始 HTML、CSS 和图片；任意区域轻触打开菜单，滑动翻页 |
| 阅读设置 | 字号、纸色、纯白、夜读与连续滚动；目录打开定位到当前章节 |
| 独立听书页 | 播放暂停、章节百分比、0.5～2 倍速、前后 15 秒、上一章／下一章 |
| 系统音色 | 列出本书语言的系统可用声音，按语言保存选择，支持恢复自动选择 |
| 原文同步 | 当前句高亮、跟随朗读自动翻页、当前可见段落及选文“从这里听” |
| 后台听书 | 配置后台音频会话、锁屏信息与远程控制，处理耳机断开和音频中断 |
| 本地数据 | 私有目录保存书籍与进度；CAF 语音缓存按需生成、预取并回收 |

当前句准备好即可开始播放，不等待整章合成。前后 15 秒使用真实音频时长跨句定位；未缓存的句子会按需合成，因此跨越较多句子时可能短暂准备。

## 在 Xcode 中运行

1. 克隆仓库并打开工程：

   ```bash
   git clone https://github.com/BestJerry/FreeReading_iOS.git
   cd FreeReading_iOS
   open FreeReading.xcodeproj
   ```

2. 使用 Xcode 16 或更新版本，等待 Swift Package 依赖解析完成。
3. 选择 **FreeReading** Scheme 和一个 iOS 17+ 目标，然后运行。
4. 在真机上运行时，在 **Signing & Capabilities** 中选择自己的 Apple Development Team，并按需要修改 Bundle Identifier。

初始工程没有预置开发者证书、签名团队或 Provisioning Profile。当前仓库提供源码，没有分发签名的 IPA 或 TestFlight 版本。

只编译 iOS 模拟器目标、不启动设备：

```bash
xcodebuild -project FreeReading.xcodeproj -scheme FreeReading \
  -configuration Debug -jobs 2 -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build-ios CODE_SIGNING_ALLOWED=NO build
```

EPUB、索引和播放时间轴的核心模块支持在 macOS 14+ 上独立测试：

```bash
swift test --jobs 2
```

工程已经提交，无须安装第三方工程生成器。添加或移除 App 源文件后，也可以运行 `python3 Scripts/generate_project.py`，按目录重新生成工程；签名团队应由本机 Xcode 选择。

## 使用

1. 点击书架“导入 EPUB”，或通过系统文档打开方式将 EPUB 交给 FreeReading。导入完成后显示正文。
2. 轻触正文任意区域展开或收起菜单，滑动翻页。通过目录跳转，在设置中调整字号、主题和滚动方式。
3. 打开“听书”，点击播放。返回阅读页或书架后，音频继续播放；“结束听书”才会清除当前会话。
4. 在听书页选择音色、倍速、前后 15 秒及相邻章节。“从阅读处听”从当前可见段落开始；长按选文后可使用“从这里听”。
5. 原文页按当前朗读句高亮并自动翻页。手动浏览或选文会暂时脱离跟随，点击“继续跟随”恢复；明确关闭自动翻页后，会记住该偏好。

仓库附带原创示例 [《山间来信》](samples/山间来信.epub)，与 Android 项目共用；没有加入用户提供的书籍。

## 与 Android 的对应及边界

- 支持无 DRM、可重排、从左至右排版的 EPUB 2/3，以及 UTF-8／UTF-16 正文和标准 IDPF／Adobe 字体混淆。固定版式、从右向左排版、扫描图片书、加密正文和外部正文不在当前支持范围内。
- 导入原文件上限为 100 MiB，解压内容上限为 512 MiB、单资源 32 MiB；支持最多 50 万句、2000 万 UTF-16 正文单元及 2 万个资源。超限返回明确错误，不静默截断书籍。
- 句子共享原段落及 UTF-16 范围；浏览器高亮与听书索引使用相同文本坐标，保留原文内联排版。
- 章节进度按正文长度加权，结合当前句音频位置推进；章节边界使用 EPUB spine 正文资源。同一资源的多个目录锚点可以单独跳转，但章节进度合并计算，沿用 Android 的定义。
- 音色切换保留倍速和播放／暂停意图；不同声音长度不同，句内恢复采用近似比例。
- iOS 不提供可靠的“每种声音已完全下载且无需联网”标志。应用使用系统可用音色，不接入第三方语音服务；离线使用前应在系统语音设置中准备所需声音。列表可见不等于已经验证了该声音在飞行模式下的行为。
- 语音缓存上限为 256 MiB，可被系统回收；再次播放时按需重新生成，不提供永久有声书导出。
- 当前打开书籍时读取并缓存最近一本完整听书索引，尚未移植 Android 的阅读首屏与听书索引分阶段加载优化。进程硬退出后留下的暂存目录也尚未自动回收。
- iOS 的后台音频、锁屏和系统中断处理已接入原生 API；真实 TTS、锁屏及蓝牙路由仍需设备专项验证。

## 数据与隐私

书籍及进度保存于应用的 Application Support 私有目录，合成音频保存于 Caches。原文件复制到本地后不再依赖来源文件路径；移除书籍会删除相应文件、进度与语音缓存。卸载会清除应用本地数据，目前没有云端同步。

应用没有账户、分析统计、广告、麦克风采集或第三方语音接口。阅读器阻断 HTTP(S) 资源，导入时移除书内脚本和危险属性。系统声音的下载、可用性和处理行为由 iOS 管理。

## 代码结构

| 路径 | 职责 |
| --- | --- |
| `App/Library/` | 书架、导入 UI、错误与阅读导航 |
| `App/Reader/` | WebKit 排版、高亮、原文定位、目录、独立听书页 |
| `App/Audio/` | 系统语音合成、CAF 缓存、播放器、后台会话与媒体控制 |
| `Sources/FreeReadingCore/` | EPUB 校验与解析、共享索引、书库与进度、播放时间轴 |
| `Tests/FreeReadingCoreTests/` | 本地 XCTest 与原创 EPUB 夹具 |
| `App/Resources/` | 阅读脚本、原创应用图标、隐私清单及第三方许可 |
| `Scripts/` | 可复现的工程和图标生成脚本 |

类职责与关键方法使用中文注释。[模块接口](docs/IntegrationContract.md)记录各层之间的边界。

## 验证

- **33 条本地测试全部通过**，其中包含真实 WebKit 集成回归。核心单测覆盖 EPUB 导入与重开、重复导入、路径／CRC／容量边界、目录、UTF-16 分句、进度批次保护及真实音频时间跨句定位。
- 本地 WebKit 集成回归加载导入后的真实 `.xhtml` 文件，核对原文文本、句子范围、高亮矩形、字号、分页与滚动；没有用纯 HTML 替代真实文件入口。
- 完整 iOS 模拟器目标已无签名编译通过；没有启动手机或模拟器。实际 TTS、锁屏和蓝牙播放仍待设备验证。
- 可运行 `bash Scripts/check.sh` 一次完成本地单测与无签名编译。

## 依赖及许可

- [ZIPFoundation 0.9.20](https://github.com/weichsel/ZIPFoundation/tree/0.9.20)：ZIP 资源读取与校验。
- [SwiftSoup 2.14.4](https://github.com/scinfu/SwiftSoup/tree/2.14.4)：HTML 解析与段落索引。
- Apple SwiftUI、WebKit、AVFoundation 和 MediaPlayer。

依赖版本通过 `Package.resolved` 锁定，完整第三方许可打包在应用资源中，见[许可记录](docs/ThirdPartyNotices.md)。本仓库尚未单独声明项目许可证。
