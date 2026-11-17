import SwiftUI
import WebKit
import FreeReadingCore

/// 浏览器返回的原段落位置；offset 与原文 textContent 使用同一 UTF-16 坐标。
struct ReaderAnchor: Equatable {
    var sectionID: Int?
    var offset: Int
    var progress: Double

    init?(_ value: Any) {
        guard let value = value as? [String: Any] else { return nil }
        sectionID = (value["sectionID"] as? NSNumber)?.intValue
        offset = max(0, (value["offset"] as? NSNumber)?.intValue ?? 0)
        let fraction = (value["progress"] as? NSNumber)?.doubleValue ?? 0
        progress = fraction.isFinite ? min(1, max(0, fraction)) : 0
    }
}

/// 通过独立命令标识重放导航，避免页面加载后丢失同一句的重新起播请求。
struct ReaderNavigation: Equatable {
    enum Target: Equatable { case progress(Double), section(Int, Int), fragment(String) }
    var id = UUID()
    var target: Target
    var json: [String: Any] {
        switch target {
        case .progress(let value): return ["kind": "progress", "value": value]
        case .section(let section, let offset): return ["kind": "section", "sectionID": section, "offset": offset]
        case .fragment(let value): return ["kind": "fragment", "value": value]
        }
    }
}

struct ReaderHighlight: Equatable {
    var sentence: Int
    var section: Int
    var start: Int
    var end: Int
    var navigate: Bool
    var revision: Int
    var json: [String: Any] {
        ["sectionID": section, "start": start, "end": end, "navigate": navigate]
    }
}

/// 分页和颜色参数只修改页面样式，菜单显隐不改变正文视口尺寸。
struct ReaderAppearance: Equatable {
    var fontSize: Double
    var theme: String
    var scroll: Bool
    var paper: String { theme == "night" ? "#18231e" : theme == "white" ? "#ffffff" : "#f7f5ef" }
    var ink: String { theme == "night" ? "#cbd7cb" : "#283c32" }
    var json: [String: Any] { ["fontSize": fontSize, "paper": paper, "ink": ink, "scroll": scroll] }
}

enum ReaderWebEvent {
    case ready, tap, manual, chapter(Int), anchor(ReaderAnchor), selection(Bool), link(String), failure(String), listenSelection
}

/// 仅加载书籍私有目录。书内脚本由导入层移除，网络子资源另由 WebKit 内容规则阻断。
@MainActor
struct ReaderWebView: UIViewRepresentable {
    let url: URL
    let readAccessURL: URL
    let appearance: ReaderAppearance
    let navigation: ReaderNavigation?
    let highlight: ReaderHighlight?
    let onAttach: (WKWebView) -> Void
    let onEvent: (ReaderWebEvent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ReadingWKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let scriptURL = Bundle.main.url(forResource: "ReaderBridge", withExtension: "js")
        let script = scriptURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        if let script {
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        configuration.userContentController.add(context.coordinator, name: "freeReading")
        let web = ReadingWKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.navigationDelegate = context.coordinator
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.showsHorizontalScrollIndicator = false
        web.scrollView.showsVerticalScrollIndicator = false
        web.scrollView.isDirectionalLockEnabled = true
        web.allowsLinkPreview = false
        web.onListenSelection = { context.coordinator.parent.onEvent(.listenSelection) }
        context.coordinator.web = web
        onAttach(web)
        guard script != nil else {
            onEvent(.failure("阅读脚本缺失，请重新安装应用。")); return web
        }
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "FreeReadingLocalContent", encodedContentRuleList: rules) { [weak web, weak coordinator = context.coordinator] list, error in
            Task { @MainActor in
                guard let coordinator, let web else { return }
                guard let list, error == nil else {
                    coordinator.parent.onEvent(.failure("无法建立本地阅读环境，请重试。")); return
                }
                web.configuration.userContentController.add(list)
                coordinator.rulesReady = true
                coordinator.update()
            }
        }
        return web
    }

    func updateUIView(_ web: ReadingWKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update()
    }

    static func dismantleUIView(_ uiView: ReadingWKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "freeReading")
        uiView.navigationDelegate = nil
        uiView.onListenSelection = nil
        coordinator.renderTask?.cancel()
    }

    /// 串行更新脚本状态。页面切换和外部导航都检查当前文件范围及加载代次。
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: ReaderWebView
        weak var web: ReadingWKWebView?
        var rulesReady = false
        var loadedURL: URL?
        var ready = false
        var renderTask: Task<Void, Never>?
        var appliedAppearance: ReaderAppearance?
        var appliedNavigation: UUID?
        var appliedHighlight: ReaderHighlight?
        var generation = 0

        init(_ parent: ReaderWebView) { self.parent = parent }

        func update() {
            guard rulesReady, let web else { return }
            web.scrollView.isPagingEnabled = !parent.appearance.scroll
            if loadedURL != parent.url {
                generation += 1
                renderTask?.cancel()
                renderTask = nil
                ready = false; loadedURL = parent.url
                appliedAppearance = nil; appliedNavigation = nil; appliedHighlight = nil
                web.loadFileURL(parent.url, allowingReadAccessTo: parent.readAccessURL)
                return
            }
            guard ready else { return }
            // 不取消已经进入 WebKit 的 apply；完成后再处理最新请求，防止 DOM 与缓存状态错位。
            guard renderTask == nil else { return }
            let token = generation
            renderTask = Task { [weak self, weak web] in
                guard let self, let web else { return }
                while !Task.isCancelled && self.generation == token && self.ready {
                    let appearance = self.parent.appearance
                    let navigation = self.parent.navigation
                    let highlight = self.parent.highlight
                    var script: [String] = []
                    if self.appliedAppearance != appearance {
                        script.append("window.FreeReading.configure(" + Self.json(appearance.json) + ");")
                        self.appliedAppearance = appearance
                    }
                    if let navigation, self.appliedNavigation != navigation.id {
                        script.append("window.FreeReading.navigate(" + Self.json(navigation.json) + ");")
                        self.appliedNavigation = navigation.id
                    }
                    if self.appliedHighlight != highlight {
                        script.append("window.FreeReading.highlight(" + (highlight.map { Self.json($0.json) } ?? "null") + ");")
                        self.appliedHighlight = highlight
                    }
                    if script.isEmpty { break }
                    do {
                        _ = try await ReaderJavaScript.evaluate("if(window.FreeReading){" + script.joined() + "}", in: web)
                    } catch {
                        if self.generation == token && !Task.isCancelled {
                            self.parent.onEvent(.failure("阅读页面更新失败，请返回书架后重试。"))
                        }
                        break
                    }
                }
                if self.generation == token { self.renderTask = nil }
            }
        }

        static func json(_ value: Any) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
                  let text = String(data: data, encoding: .utf8) else { return "null" }
            return text
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard webView.url?.standardizedFileURL == parent.url.standardizedFileURL else { return }
            ready = true
            parent.onEvent(.ready)
            update()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { parent.onEvent(.failure(error.localizedDescription)) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { parent.onEvent(.failure(error.localizedDescription)) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if navigationAction.navigationType == .linkActivated {
                parent.onEvent(.link(url.absoluteString)); decisionHandler(.cancel); return
            }
            let root = parent.readAccessURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            let file = url.resolvingSymlinksInPath().standardizedFileURL.path
            let expected = parent.url.resolvingSymlinksInPath().standardizedFileURL.path
            decisionHandler(url.isFileURL && file.hasPrefix(root) && file == expected && navigationAction.targetFrame?.isMainFrame == true ? .allow : .cancel)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.webView === web,
                  message.frameInfo.request.url?.standardizedFileURL == parent.url.standardizedFileURL,
                  let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            let value = body["value"] as? [String: Any] ?? [:]
            switch type {
            case "tap": parent.onEvent(.tap)
            case "manual": parent.onEvent(.manual)
            case "chapter":
                if let delta = value["delta"] as? Int, delta == 1 || delta == -1 { parent.onEvent(.chapter(delta)) }
            case "anchor", "ready":
                if let anchor = ReaderAnchor(value) { parent.onEvent(.anchor(anchor)) }
            case "selection":
                let active = value["active"] as? Bool ?? false
                web?.selectionAvailable = active
                parent.onEvent(.selection(active))
            case "link":
                if let href = value["href"] as? String, href.utf8.count <= 8192 { parent.onEvent(.link(href)) }
            default: break
            }
        }
    }
}

/// 在系统选文菜单加入「从这里听」，同时保留复制等默认编辑操作。
@MainActor
final class ReadingWKWebView: WKWebView {
    var onListenSelection: (() -> Void)?
    var selectionAvailable = false

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        let action = UIAction(title: "从这里听", image: UIImage(systemName: "headphones")) { [weak self] _ in self?.onListenSelection?() }
        builder.insertSibling(UIMenu(options: .displayInline, children: [action]), afterMenu: .standardEdit)
    }
}
