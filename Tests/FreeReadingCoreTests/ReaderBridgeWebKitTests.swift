#if os(macOS)
import XCTest
import AppKit
import WebKit
@testable import FreeReadingCore

/// 在真实桌面 WebKit 中读取导入后的 XHTML，覆盖 HTML 索引与浏览器 MIME／命名空间边界。
@MainActor
final class ReaderBridgeWebKitTests: XCTestCase {
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
                sections: Array.from(document.querySelectorAll("[data-fr-section]")).map(function(element) {
                    return {id: Number(element.getAttribute("data-fr-section")), text: element.textContent};
                })
            };
        })()
        """)
        let state = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual((state["parserErrors"] as? NSNumber)?.intValue, 0, "导入后序列化的 XHTML 必须可由真实 XML 浏览器解析。")
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
            window.FreeReading.configure({fontSize:20,paper:"#f7f5ef",ink:"#283c32",scroll:false});
            window.FreeReading.highlight(\(json));
            var layer = document.getElementById("fr-highlight-layer");
            var style = document.getElementById("fr-reader-style");
            return {
                rectangles: layer ? layer.childElementCount : 0,
                styleNamespace: style ? style.namespaceURI : null,
                layerNamespace: layer ? layer.namespaceURI : null,
                fontSize: getComputedStyle(document.body).fontSize,
                paged: document.documentElement.classList.contains("fr-paged")
            };
        })()
        """)
        let paint = try XCTUnwrap(drawn as? [String: Any])
        XCTAssertGreaterThan((paint["rectangles"] as? NSNumber)?.intValue ?? 0, 0, "跨页句子需要生成真实 DOM Range 高亮矩形。")
        XCTAssertEqual(paint["styleNamespace"] as? String, "http://www.w3.org/1999/xhtml")
        XCTAssertEqual(paint["layerNamespace"] as? String, "http://www.w3.org/1999/xhtml")
        XCTAssertEqual(paint["fontSize"] as? String, "20px")
        XCTAssertEqual(paint["paged"] as? Bool, true)

        let cleared = try await web.evaluateJavaScript("""
        (function() {
            window.FreeReading.highlight(null);
            window.FreeReading.configure({fontSize:24,paper:"#18231e",ink:"#cbd7cb",scroll:true});
            return {count:document.getElementById("fr-highlight-layer").childElementCount,
                    scroll:document.documentElement.classList.contains("fr-scroll"),
                    size:getComputedStyle(document.body).fontSize};
        })()
        """)
        let scrolling = try XCTUnwrap(cleared as? [String: Any])
        XCTAssertEqual((scrolling["count"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(scrolling["scroll"] as? Bool, true)
        XCTAssertEqual(scrolling["size"] as? String, "24px")
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
