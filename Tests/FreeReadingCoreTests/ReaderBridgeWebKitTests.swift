#if os(macOS)
import XCTest
import AppKit
import WebKit
@testable import FreeReadingCore

/// 在真实桌面 WebKit 中读取导入后的 XHTML，覆盖 HTML 索引与浏览器 MIME／命名空间边界。
@MainActor
final class ReaderBridgeWebKitTests: XCTestCase {
    /// 真正跨多页断言 Range 与视口相交，避免仅验证 CSS 类名却漏掉 RTL 的负滚动坐标。
    func testPagedRangeVisibilityAndRestoreAcrossRTLAndLayoutChanges() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FreeReadingPagination-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let phrase = "هذه فقرة للقراءة المتزامنة مع الصوت. 原文😀范围与分页保持一致。 "
        let before = String(repeating: phrase, count: 6)
        let selected = "目标😀原文"
        let after = String(repeating: phrase, count: 8)
        let body = (0..<48).map { "<p data-fr-section=\"\($0)\" id=\"section-\($0)\">\(before)<em>\(selected)</em>\(after)</p>" }.joined()
        let html = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><meta charset=\"utf-8\"/><title>分页测试</title></head><body>" + body + "</body></html>"
        let url = directory.appendingPathComponent("pagination.xhtml")
        try html.write(to: url, atomically: true, encoding: .utf8)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try String(contentsOf: root.appendingPathComponent("App/Resources/ReaderBridge.js"), encoding: .utf8)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let messages = ReaderTestMessages()
        configuration.userContentController.add(messages, name: "freeReading")
        configuration.userContentController.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 360, height: 640), configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 640), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = web
        web.setFrameSize(NSSize(width: 360, height: 640)); web.layoutSubtreeIfNeeded()
        let loaded = expectation(description: "加载多页 XHTML")
        let loader = ReaderTestNavigation(completion: { loaded.fulfill() })
        web.navigationDelegate = loader
        defer { web.stopLoading(); web.navigationDelegate = nil; configuration.userContentController.removeScriptMessageHandler(forName: "freeReading"); window.close() }
        web.loadFileURL(url, allowingReadAccessTo: directory)
        await fulfillment(of: [loaded], timeout: 20)
        guard loader.didComplete else { throw NSError(domain: "FreeReading.WebKitTests", code: 3) }
        if let error = loader.error { throw error }
        let start = before.utf16.count, end = start + selected.utf16.count

        for direction in ["ltr", "rtl"] {
            let value = try await web.readerTestJavaScript("""
                window.FreeReading.configure({fontSize:22,paper:'#fff',ink:'#222',scroll:false,direction:direction});
                window.FreeReading.navigate({kind:'section',sectionID:28,offset:start});
                window.FreeReading.highlight({sectionID:28,start:start,end:end,navigate:true});
                await new Promise(resolve => setTimeout(resolve, 80));
                const marks = Array.from(document.getElementById('fr-highlight-layer').children);
                const visible = marks.some(mark => { const r=mark.getBoundingClientRect(); return r.width>0 && r.height>0 && r.right>0 && r.left<innerWidth && r.bottom>0 && r.top<innerHeight; });
                return {visible:visible,anchor:window.FreeReading.anchor(),x:scrollX,width:document.scrollingElement.scrollWidth,
                        text:document.querySelector('[data-fr-section="28"]').textContent.slice(start,end),direction:getComputedStyle(document.body).direction};
                """, arguments: ["direction": direction, "start": start, "end": end], in: nil, contentWorld: .page)
            let state = try XCTUnwrap(value as? [String: Any])
            XCTAssertEqual(state["visible"] as? Bool, true, "\(direction) 当前朗读 Range 必须实际出现在视口。")
            XCTAssertEqual(state["text"] as? String, selected)
            XCTAssertEqual(state["direction"] as? String, direction)
            XCTAssertGreaterThan((state["width"] as? NSNumber)?.doubleValue ?? 0, 360 * 5)
            let x = (state["x"] as? NSNumber)?.doubleValue ?? 0
            if direction == "rtl" { XCTAssertLessThan(x, -360) } else { XCTAssertGreaterThan(x, 360) }
            let saved = try XCTUnwrap(state["anchor"] as? [String: Any])
            let savedSection = try XCTUnwrap(saved["sectionID"] as? NSNumber).intValue
            let savedOffset = try XCTUnwrap(saved["offset"] as? NSNumber).intValue

            // 用真实 DOM 游标模拟离页重开；调大字号、切滚动后恢复的字符仍应可见。
            let restored = try await web.readerTestJavaScript("""
                window.FreeReading.highlight(null);
                window.FreeReading.navigate({kind:'progress',value:0});
                window.FreeReading.configure({fontSize:27,paper:'#fff',ink:'#222',scroll:true,direction:direction});
                window.FreeReading.navigate({kind:'section',sectionID:sectionID,offset:offset});
                await new Promise(resolve => setTimeout(resolve, 80));
                const length=document.querySelector('[data-fr-section="'+sectionID+'"]').textContent.length;
                window.FreeReading.highlight({sectionID:sectionID,start:offset,end:Math.min(length,offset+8),navigate:false});
                const visible=Array.from(document.getElementById('fr-highlight-layer').children).some(mark=>{const r=mark.getBoundingClientRect();return r.right>0&&r.left<innerWidth&&r.bottom>0&&r.top<innerHeight;});
                return {visible:visible,y:scrollY};
                """, arguments: ["direction": direction, "sectionID": savedSection, "offset": savedOffset], in: nil, contentWorld: .page)
            let restoredState = try XCTUnwrap(restored as? [String: Any])
            XCTAssertEqual(restoredState["visible"] as? Bool, true, "布局变化后的恢复点不能只恢复章节而丢失段内偏移。")
            XCTAssertGreaterThan((restoredState["y"] as? NSNumber)?.doubleValue ?? 0, 640)

            let terminal = try await web.readerTestJavaScript("""
                window.FreeReading.configure({fontSize:22,paper:'#fff',ink:'#222',scroll:false,direction:direction});
                window.FreeReading.navigate({kind:'progress',value:1});
                await new Promise(resolve=>setTimeout(resolve,80));
                return window.FreeReading.anchor();
                """, arguments: ["direction": direction], in: nil, contentWorld: .page)
            let last = try XCTUnwrap(terminal as? [String: Any])
            XCTAssertEqual((last["progress"] as? NSNumber)?.doubleValue ?? -1, 1, accuracy: 0.001)
            XCTAssertEqual((last["sectionID"] as? NSNumber)?.intValue, 47)

            for (fraction, forward, expected) in [(1.0, true, 1), (1.0, false, 0), (0.0, false, -1), (0.5, true, 0)] {
                messages.chapters.removeAll()
                let dx = (forward ? -120 : 120) * (direction == "rtl" ? -1 : 1)
                _ = try await web.readerTestJavaScript("""
                    window.FreeReading.navigate({kind:'progress',value:fraction});
                    await new Promise(resolve=>setTimeout(resolve,80));
                    function touchEvent(type,x) {
                        const event=new Event(type,{bubbles:true});
                        Object.defineProperty(event,type==='touchend'?'changedTouches':'touches',{value:[{clientX:x,clientY:200}]});
                        document.dispatchEvent(event);
                    }
                    touchEvent('touchstart',180);touchEvent('touchmove',180+dx);touchEvent('touchend',180+dx);
                    await new Promise(resolve=>setTimeout(resolve,60));
                    """, arguments: ["fraction": fraction, "dx": dx], in: nil, contentWorld: .page)
                XCTAssertEqual(messages.chapters, expected == 0 ? [] : [expected],
                    "\(direction) 物理滑动应保持 spine 章序，而且只在对应页边界换章。")
            }
        }
    }

    func testImportedXHTMLHasMatchingTextAndExecutableReaderHighlight() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FreeReadingWebKit-" + UUID().uuidString)
        let repository = try BookRepository(root: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try XCTUnwrap(Bundle.module.url(forResource: "reading-sample", withExtension: "epub", subdirectory: "Fixtures"))
        let book = try await repository.importEPUB(from: source)
        let chapter = try XCTUnwrap(book.chapters.max { first, second in
            book.sections.filter { $0.chapterIndex == first.id }.reduce(0) { $0 + $1.text.utf16.count } <
                book.sections.filter { $0.chapterIndex == second.id }.reduce(0) { $0 + $1.text.utf16.count }
        })
        let url = try repository.contentURL(bookID: book.record.id, href: chapter.href)
        XCTAssertEqual(url.pathExtension.lowercased(), "xhtml", "必须使用真实 XHTML 文件 MIME，不能通过 loadHTMLString 绕过 XML 解析。")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try String(contentsOf: root.appendingPathComponent("App/Resources/ReaderBridge.js"), encoding: .utf8)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 360, height: 640), configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 640),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        web.setFrameSize(NSSize(width: 360, height: 640))
        web.layoutSubtreeIfNeeded()
        let loaded = expectation(description: "本地 XHTML 完成 WebKit 导航")
        let loader = ReaderTestNavigation(completion: { loaded.fulfill() })
        web.navigationDelegate = loader
        defer {
            web.stopLoading()
            web.navigationDelegate = nil
            window.close()
        }
        web.loadFileURL(url, allowingReadAccessTo: repository.bookDirectory(id: book.record.id).appendingPathComponent("content"))
        await fulfillment(of: [loaded], timeout: 20)
        guard loader.didComplete else {
            throw NSError(domain: "FreeReading.WebKitTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "WebKit 导航未在时限内完成"])
        }
        if let error = loader.error { throw error }

        let result = try await web.evaluateJavaScript("""
        (function() {
            return {
                parserErrors: document.getElementsByTagName("parsererror").length,
                bridge: typeof window.FreeReading,
                viewportCount: document.querySelectorAll('meta[name="viewport"]').length,
                viewportContent: document.querySelector('meta[name="viewport"]')?.getAttribute('content'),
                viewportNamespace: document.querySelector('meta[name="viewport"]')?.namespaceURI,
                sections: Array.from(document.querySelectorAll("[data-fr-section]")).map(function(element) {
                    return {id: Number(element.getAttribute("data-fr-section")), text: element.textContent};
                })
            };
        })()
        """)
        let state = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual((state["parserErrors"] as? NSNumber)?.intValue, 0, "导入后序列化的 XHTML 必须可由真实 XML 浏览器解析。")
        XCTAssertEqual((state["viewportCount"] as? NSNumber)?.intValue, 1, "未声明移动视口的真实 EPUB 也必须在桥接初始化时补齐。")
        XCTAssertEqual(state["viewportContent"] as? String, "width=device-width, initial-scale=1")
        XCTAssertEqual(state["viewportNamespace"] as? String, "http://www.w3.org/1999/xhtml")
        let domSections = try XCTUnwrap(state["sections"] as? [[String: Any]])
        let expected = book.sections.filter { $0.chapterIndex == chapter.id }
        XCTAssertEqual(domSections.count, expected.count)
        var textByID: [Int: String] = [:]
        for value in domSections {
            if let id = (value["id"] as? NSNumber)?.intValue, let text = value["text"] as? String { textByID[id] = text }
        }
        for section in expected {
            XCTAssertEqual(textByID[section.id], section.text, "原段落 \(section.id) 的空白与 UTF-16 原文必须一致。")
        }
        guard state["bridge"] as? String == "object" else {
            XCTFail("ReaderBridge 未成功初始化：请检查 XHTML 的 HTML 命名空间及 createElement／style 支持。")
            return
        }
        let sentence = try XCTUnwrap(book.sentences.last(where: { $0.chapterIndex == chapter.id }))
        let payload: [String: Any] = ["sectionID": sentence.sectionID, "start": sentence.range.start, "end": sentence.range.end, "navigate": true]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let drawn = try await web.evaluateJavaScript("""
        (function() {
            var originalViewport = document.querySelector('meta[name="viewport"]');
            window.FreeReading.configure({fontSize:20,paper:"#f7f5ef",ink:"#283c32",scroll:false});
            window.FreeReading.highlight(\(json));
            var layer = document.getElementById("fr-highlight-layer");
            var style = document.getElementById("fr-reader-style");
            return {
                sameViewport: originalViewport === document.querySelector('meta[name="viewport"]'),
                rectangles: layer ? layer.childElementCount : 0,
                styleNamespace: style ? style.namespaceURI : null,
                layerNamespace: layer ? layer.namespaceURI : null,
                fontSize: getComputedStyle(document.body).fontSize,
                paged: document.documentElement.classList.contains("fr-paged")
            };
        })()
        """)
        let paint = try XCTUnwrap(drawn as? [String: Any])
        XCTAssertEqual(paint["sameViewport"] as? Bool, true, "再次配置应复用既有视口节点，避免不必要的缩放重置。")
        XCTAssertGreaterThan((paint["rectangles"] as? NSNumber)?.intValue ?? 0, 0, "跨页句子需要生成真实 DOM Range 高亮矩形。")
        XCTAssertEqual(paint["styleNamespace"] as? String, "http://www.w3.org/1999/xhtml")
        XCTAssertEqual(paint["layerNamespace"] as? String, "http://www.w3.org/1999/xhtml")
        XCTAssertEqual(paint["fontSize"] as? String, "20px")
        XCTAssertEqual(paint["paged"] as? Bool, true)

        let cleared = try await web.evaluateJavaScript("""
        (function() {
            window.FreeReading.highlight(null);
            // 模拟出版方遗留的桌面宽度和禁止缩放指令，以及一个重复的 viewport。
            document.querySelector('meta[name="viewport"]').setAttribute('content', 'width=980, initial-scale=0.3, user-scalable=no');
            var duplicate = document.createElementNS('http://www.w3.org/1999/xhtml', 'meta');
            duplicate.setAttribute('name', ' VIEWPORT ');
            duplicate.setAttribute('content', 'width=1024, maximum-scale=1');
            document.head.appendChild(duplicate);
            window.FreeReading.configure({fontSize:24,paper:"#18231e",ink:"#cbd7cb",scroll:true});
            return {count:document.getElementById("fr-highlight-layer").childElementCount,
                    scroll:document.documentElement.classList.contains("fr-scroll"),
                    size:getComputedStyle(document.body).fontSize,
                    viewports:Array.from(document.querySelectorAll('meta[name]')).filter(function(meta) {
                        return meta.getAttribute('name').trim().toLowerCase() === 'viewport';
                    }).map(function(meta) { return {content:meta.getAttribute('content'),namespace:meta.namespaceURI}; })};
        })()
        """)
        let scrolling = try XCTUnwrap(cleared as? [String: Any])
        XCTAssertEqual((scrolling["count"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(scrolling["scroll"] as? Bool, true)
        XCTAssertEqual(scrolling["size"] as? String, "24px")
        let viewports = try XCTUnwrap(scrolling["viewports"] as? [[String: Any]])
        XCTAssertEqual(viewports.count, 1, "重复配置不得累加 viewport；出版方的重复声明也应合并。")
        XCTAssertEqual(viewports.first?["content"] as? String, "width=device-width, initial-scale=1", "修正桌面视口且不保留 user-scalable=no/maximum-scale 限制。")
        XCTAssertEqual(viewports.first?["namespace"] as? String, "http://www.w3.org/1999/xhtml")
    }
}

@MainActor
private extension WKWebView {
    /// 隐藏窗口会暂停 animationFrame；JS 自身用计时器等待，原生再加截止时间以免 CI 永久挂起。
    func readerTestJavaScript(_ script: String, arguments: [String: Any], in frame: WKFrameInfo?, contentWorld: WKContentWorld) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            let pending = ReaderTestJavaScriptResult(continuation)
            pending.timeout = Task {
                do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
                pending.finish(.failure(NSError(domain: "FreeReading.WebKitTests", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "WebKit JavaScript 等待超过 8 秒"])))
            }
            callAsyncJavaScript(script, arguments: arguments, in: frame, in: contentWorld) { result in pending.finish(result) }
        }
    }
}

@MainActor
private final class ReaderTestJavaScriptResult {
    var continuation: CheckedContinuation<Any, Error>?
    var timeout: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<Any, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Any, Error>) {
        guard let continuation else { return }
        self.continuation = nil; timeout?.cancel(); timeout = nil
        continuation.resume(with: result)
    }
}

@MainActor
private final class ReaderTestMessages: NSObject, WKScriptMessageHandler {
    var chapters: [Int] = []
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["type"] as? String == "chapter",
              let value = body["value"] as? [String: Any], let delta = value["delta"] as? Int else { return }
        chapters.append(delta)
    }
}

@MainActor
private final class ReaderTestNavigation: NSObject, WKNavigationDelegate {
    var error: Error?
    private var completed = false
    var didComplete: Bool { completed }
    let completion: () -> Void
    init(completion: @escaping () -> Void) { self.completion = completion }
    private func finish(_ error: Error? = nil) {
        guard !completed else { return }
        completed = true; self.error = error; completion()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(NSError(domain: "FreeReading.WebKitTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "WebKit 内容进程被终止"]))
    }
}
#endif
