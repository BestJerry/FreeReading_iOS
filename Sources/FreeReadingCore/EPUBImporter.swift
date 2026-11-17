import Foundation
import CryptoKit
import SwiftSoup
import ZIPFoundation

/// 只解析本地可重排 EPUB；在暂存目录内检查、解压、净化与建索引，由仓库完成最终提交。
struct EPUBImporter {
    private struct Item { let id: String; let href: String; let mediaType: String; let properties: Set<String> }
    private let files = FileManager.default

    func open(source: URL, contentRoot: URL, id: String, progress: @Sendable (ImportProgress) -> Void) throws -> SpeechBook {
        progress(ImportProgress(stage: .validating))
        try extract(source, into: contentRoot)
        guard !files.fileExists(atPath: contentRoot.appendingPathComponent("META-INF/rights.xml").path) else { throw BookError.invalid("暂不支持 DRM 书籍") }
        let container = try readEPUBXML(Data(contentsOf: EPUBPath.file("META-INF/container.xml", in: contentRoot)))
        guard let fullPath = container.descendants("rootfile").first?.attributes["full-path"] else { throw BookError.invalid("EPUB 缺少内容清单") }
        let packageHref = try EPUBPath.resolve(fullPath).href
        let package = try readEPUBXML(Data(contentsOf: EPUBPath.file(packageHref, in: contentRoot)))
        guard let opf = package.descendants("package").first,
              let manifest = opf.children.first(where: { $0.name == "manifest" }),
              let spine = opf.children.first(where: { $0.name == "spine" }) else { throw BookError.invalid("EPUB 清单结构不完整") }
        let metadata = opf.children.first(where: { $0.name == "metadata" })
        let metadataNodes = metadata?.children ?? []
        if metadataNodes.contains(where: {
            ($0.attributes["property"] == "rendition:layout" && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == "pre-paginated") ||
            ($0.attributes["name"] == "fixed-layout" && $0.attributes["content"] == "true")
        }) || spine.attributes["page-progression-direction"] == "rtl" {
            throw BookError.invalid("暂不支持固定版式或从右向左排版的 EPUB")
        }
        var items: [String: Item] = [:]
        for node in manifest.children where node.name == "item" {
            guard let itemID = node.attributes["id"], let reference = node.attributes["href"], let type = node.attributes["media-type"], items[itemID] == nil else { throw BookError.invalid("EPUB 资源清单包含重复或缺失字段") }
            let href = try EPUBPath.resolve(reference, relativeTo: packageHref).href
            items[itemID] = Item(id: itemID, href: href, mediaType: type, properties: Set(node.attributes["properties", default: ""].split(separator: " ").map(String.init)))
        }
        try decodeFontsIfNeeded(in: contentRoot, package: opf, items: items)
        let ordered = try spine.children.filter { $0.name == "itemref" && $0.attributes["linear"] != "no" }.map { node -> Item in
            guard let ref = node.attributes["idref"], let item = items[ref], ["application/xhtml+xml", "text/html"].contains(item.mediaType), !node.attributes["properties", default: ""].contains("rendition:layout-pre-paginated") else { throw BookError.invalid("正文资源缺失或不是可重排 HTML") }
            return item
        }
        guard !ordered.isEmpty, Set(ordered.map(\.href)).count == ordered.count else { throw BookError.invalid("EPUB 缺少有效正文或重复引用正文") }
        var chapters = ordered.enumerated().map { BookChapter(id: $0.offset, href: $0.element.href, title: "第 \($0.offset + 1) 节") }
        let contents = try readContents(items: items, spine: spine, chapters: chapters, contentRoot: contentRoot)
        var titled = Set<Int>()
        for entry in contents where chapters.indices.contains(entry.chapterIndex) {
            if titled.insert(entry.chapterIndex).inserted { chapters[entry.chapterIndex].title = entry.title }
        }
        var sections: [BookSection] = []
        var sentences: [SpeechSentence] = []
        var textCharacters = 0
        progress(ImportProgress(stage: .indexing, completed: 0, total: Int64(chapters.count)))
        for chapter in chapters {
            try Task.checkCancellation()
            let file = try EPUBPath.file(chapter.href, in: contentRoot)
            let html = try readHTML(file)
            let document = try SwiftSoup.parse(html)
            document.outputSettings().prettyPrint(pretty: false)
            try sanitize(document)
            guard let body = document.body() else { throw BookError.invalid("EPUB 正文没有 body 元素") }
            try index(body: body, chapter: chapter.id, sections: &sections, sentences: &sentences, textCharacters: &textCharacters)
            // 序列化后的文本节点和记录的 UTF-16 字符串共用同一 DOM，避免白空格归一化造成范围偏移。
            try Data(try document.outerHtml().utf8).write(to: file, options: bookDataWriteOptions)
            progress(ImportProgress(stage: .indexing, completed: Int64(chapter.id + 1), total: Int64(chapters.count)))
        }
        guard !sentences.isEmpty else { throw BookError.invalid("这本 EPUB 没有可朗读的正文，暂不支持扫描图片书") }
        let title = metadataNodes.first(where: { $0.name == "title" })?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = metadataNodes.filter { $0.name == "creator" }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "、")
        let language = metadataNodes.first(where: { $0.name == "language" })?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let coverID = metadataNodes.first(where: { $0.name == "meta" && $0.attributes["name"] == "cover" })?.attributes["content"]
        let cover = items.values.first(where: { $0.properties.contains("cover-image") }) ?? coverID.flatMap { items[$0] }
        let coverPath = cover.flatMap { item in item.mediaType.hasPrefix("image/") && files.fileExists(atPath: contentRoot.appendingPathComponent(item.href).path) ? "content/" + item.href : nil }
        let record = BookRecord(id: id, title: title?.isEmpty == false ? String(title!.prefix(2048)) : "未命名书籍", author: String(author.prefix(2048)), language: language?.isEmpty == false ? String(language!.prefix(128)) : "zh-CN", coverPath: coverPath, chapterCount: chapters.count, sentenceCount: sentences.count)
        return SpeechBook(record: record, chapters: chapters, sections: sections, sentences: sentences, contents: contents.isEmpty ? chapters.map { ContentsEntry(id: "chapter-\($0.id)", title: $0.title, chapterIndex: $0.id) } : contents)
    }

    /// 同时验证声明容量和实际输出字节，并比较 CRC；禁止符号链接、重复路径和大小写碰撞。
    private func extract(_ source: URL, into root: URL) throws {
        let archive: Archive
        do { archive = try Archive(url: source, accessMode: .read) } catch { throw BookError.invalid("文件不是完整的 EPUB 压缩包") }
        var entries: [Entry] = []
        for entry in archive {
            try Task.checkCancellation()
            guard entries.count < BookLimits.resources else { throw BookError.invalid("书籍资源数量过多") }
            entries.append(entry)
        }
        var paths = Set<String>(); var declared: UInt64 = 0
        for entry in entries {
            try Task.checkCancellation()
            let path = try EPUBPath.archivePath(entry.path)
            guard entry.type != .symlink, paths.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  entry.uncompressedSize <= BookLimits.resourceBytes, entry.uncompressedSize <= BookLimits.expandedBytes - declared else { throw BookError.invalid("EPUB 包含重复、链接资源或超出容量限制") }
            declared += entry.uncompressedSize
        }
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        var expanded: UInt64 = 0
        for entry in entries {
            try Task.checkCancellation()
            let destination = try EPUBPath.file(try EPUBPath.archivePath(entry.path), in: root)
            if entry.type == .directory { try files.createDirectory(at: destination, withIntermediateDirectories: true); continue }
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard files.createFile(atPath: destination.path, contents: nil) else { throw BookError.invalid("无法写入书籍资源") }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var count: UInt64 = 0
            let checksum = try archive.extract(entry, bufferSize: 32 * 1024) { data in
                try Task.checkCancellation()
                count += UInt64(data.count); expanded += UInt64(data.count)
                guard count <= BookLimits.resourceBytes, expanded <= BookLimits.expandedBytes else { throw BookError.invalid("EPUB 解压后超过容量限制") }
                try output.write(contentsOf: data)
            }
            guard count == entry.uncompressedSize, checksum == entry.checksum else { throw BookError.invalid("EPUB 资源校验失败，请重新获取文件") }
            try output.synchronize()
        }
        let mime = try Data(contentsOf: EPUBPath.file("mimetype", in: root))
        guard String(data: mime, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "application/epub+zip" else { throw BookError.invalid("文件不是 EPUB 格式") }
    }

    private func readHTML(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard data.count <= BookLimits.resourceBytes else { throw BookError.invalid("单个正文资源过大") }
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { text = String(data: data, encoding: .utf16) }
        else { text = String(data: data, encoding: .utf8) }
        guard let text else { throw BookError.invalid("正文不是有效的 UTF-8／UTF-16 文本") }
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    /// 保留静态排版；移除主动脚本、交互表单和危险属性，网络子资源还会由 WebView 规则拦截。
    private func sanitize(_ document: Document) throws {
        for node in try document.select("script, iframe, frame, object, embed, form, input, button, textarea, select, base, meta[http-equiv=refresh]").array() { try node.remove() }
        for element in try document.getAllElements().array() {
            if element.tagNameNormal() == "meta", (try? element.attr("http-equiv").lowercased()) == "refresh" { try element.remove(); continue }
            for attribute in element.getAttributes()?.asList() ?? [] {
                let key = attribute.getKey().lowercased()
                let value = String(String.UnicodeScalarView(attribute.getValue().unicodeScalars.filter { $0.value > 0x20 })).lowercased()
                if key.hasPrefix("on") || key == "srcdoc" || key == "data-fr-section" || ((key == "href" || key == "src" || key == "xlink:href") && (value.hasPrefix("javascript:") || value.hasPrefix("data:text/html"))) {
                    try element.removeAttr(attribute.getKey())
                }
            }
        }
    }

    /// 对无嵌套块的元素整体索引；混合容器的直接文本单独包裹，避免遗漏或重复父子文本。
    private func index(body: Element, chapter: Int, sections: inout [BookSection], sentences: inout [SpeechSentence], textCharacters: inout Int) throws {
        let blocks = Set(["address", "article", "aside", "blockquote", "dd", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul"])
        let excluded = Set(["style", "script", "noscript", "svg", "math", "template"])
        var containsBlock: [ObjectIdentifier: Bool] = [:]
        func inspect(_ node: Node, depth: Int) throws -> Bool {
            guard depth < 256 else { throw BookError.invalid("正文嵌套层次过深") }
            var result = false
            for child in node.getChildNodes() {
                let descendant = try inspect(child, depth: depth + 1)
                result = result || descendant || (child as? Element).map { blocks.contains($0.tagNameNormal()) } == true
            }
            containsBlock[ObjectIdentifier(node)] = result
            return result
        }
        _ = try inspect(body, depth: 0)
        func textContent(_ node: Node) -> String {
            if let text = node as? TextNode { return text.getWholeText() }
            return node.getChildNodes().map(textContent).joined()
        }
        func add(_ element: Element) throws {
            let text = textContent(element)
            guard text.utf16.count <= 1_000_000, text.utf16.count <= BookLimits.textCharacters - textCharacters else { throw BookError.invalid("书籍原文段落超过可支持容量") }
            let ranges = SentenceRanges.split(text)
            guard !ranges.isEmpty else { return }
            guard text.utf16.count <= 1_000_000, text.utf16.count <= BookLimits.textCharacters - textCharacters, ranges.count <= BookLimits.sentences - sentences.count else { throw BookError.invalid("书籍正文或句子数量超过可支持容量") }
            let sectionID = sections.count
            try element.attr("data-fr-section", String(sectionID))
            sections.append(BookSection(id: sectionID, chapterIndex: chapter, elementID: "fr-section-\(sectionID)", text: text))
            for range in ranges { sentences.append(SpeechSentence(id: sentences.count, sectionID: sectionID, range: range, chapterIndex: chapter)) }
            textCharacters += text.utf16.count
        }
        func visit(_ element: Element) throws {
            try Task.checkCancellation()
            if excluded.contains(element.tagNameNormal()) || element.hasAttr("hidden") || (try? element.attr("aria-hidden")) == "true" { return }
            if containsBlock[ObjectIdentifier(element)] != true { try add(element); return }
            var run: [Node] = []
            func flush() throws {
                guard let first = run.first else { return }
                let nodes = run; run.removeAll(keepingCapacity: true)
                guard nodes.map(textContent).joined().unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else { return }
                let wrapper = Element(try Tag.valueOf("span"), [])
                try first.before(wrapper)
                for child in nodes { try wrapper.appendChild(child) }
                try add(wrapper)
            }
            for child in element.getChildNodes() {
                if let childElement = child as? Element, blocks.contains(childElement.tagNameNormal()) || containsBlock[ObjectIdentifier(childElement)] == true || excluded.contains(childElement.tagNameNormal()) {
                    try flush(); try visit(childElement)
                } else { run.append(child) }
            }
            try flush()
        }
        try visit(body)
    }

    /// EPUB 3 nav 优先；否则读取 EPUB 2 NCX，保持层级及同文件片段链接。
    private func readContents(items: [String: Item], spine: EPUBXMLNode, chapters: [BookChapter], contentRoot: URL) throws -> [ContentsEntry] {
        let chapterByHref = Dictionary(uniqueKeysWithValues: chapters.map { ($0.href, $0.id) })
        var result: [ContentsEntry] = []
        if let nav = items.values.first(where: { $0.properties.contains("nav") }) {
            let doc = try SwiftSoup.parse(try readHTML(EPUBPath.file(nav.href, in: contentRoot)))
            let candidates = try doc.select("nav").array()
            let toc = candidates.first { (try? $0.attr("epub:type").split(separator: " ").contains("toc")) == true || (try? $0.attr("role")) == "doc-toc" } ?? candidates.first
            if let toc {
                for anchor in try toc.select("a[href]").array() {
                    guard let address = try? EPUBPath.resolve(anchor.attr("href"), relativeTo: nav.href), let chapter = chapterByHref[address.href] else { continue }
                    var depth = -1; var parent = anchor.parent()
                    var ancestors = 0
                    while let current = parent, current !== toc {
                        ancestors += 1
                        guard ancestors <= 256 else { throw BookError.invalid("目录嵌套层次过深") }
                        if current.tagNameNormal() == "li" { depth += 1 }; parent = current.parent()
                    }
                    guard depth < 128, result.count < BookLimits.resources else { throw BookError.invalid("目录层次或条目数量超过可支持范围") }
                    let title = try anchor.text().trimmingCharacters(in: .whitespacesAndNewlines)
                    result.append(ContentsEntry(id: "toc-\(result.count)", title: title.isEmpty ? chapters[chapter].title : String(title.prefix(2048)), chapterIndex: chapter, fragment: address.fragment, depth: max(0, depth)))
                }
            }
        } else if let ncx = spine.attributes["toc"].flatMap({ items[$0] }) ?? items.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" }) {
            let root = try readEPUBXML(Data(contentsOf: EPUBPath.file(ncx.href, in: contentRoot)))
            func visit(_ node: EPUBXMLNode, depth: Int) throws {
                if node.name == "navPoint", let src = node.children.first(where: { $0.name == "content" })?.attributes["src"] {
                    if let address = try? EPUBPath.resolve(src, relativeTo: ncx.href), let chapter = chapterByHref[address.href] {
                        guard depth < 128, result.count < BookLimits.resources else { throw BookError.invalid("目录层次或条目数量超过可支持范围") }
                        let title = node.children.first(where: { $0.name == "navLabel" })?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? chapters[chapter].title
                        result.append(ContentsEntry(id: "toc-\(result.count)", title: String(title.prefix(2048)), chapterIndex: chapter, fragment: address.fragment, depth: max(0, depth)))
                    }
                }
                for child in node.children { try visit(child, depth: node.name == "navPoint" ? depth + 1 : depth) }
            }
            try visit(root, depth: 0)
        }
        return result
    }

    /// 仅解开 EPUB 标准字体混淆；任何其他加密均拒绝，不能将 DRM 当成普通资源导入。
    private func decodeFontsIfNeeded(in root: URL, package: EPUBXMLNode, items: [String: Item]) throws {
        let file = root.appendingPathComponent("META-INF/encryption.xml")
        guard files.fileExists(atPath: file.path) else { return }
        let xml = try readEPUBXML(Data(contentsOf: file))
        let identifierID = package.attributes["unique-identifier"]
        let identifier = package.descendants("identifier").first(where: { $0.attributes["id"] == identifierID })?.text ?? ""
        for encrypted in xml.descendants("EncryptedData") {
            guard let algorithm = encrypted.descendants("EncryptionMethod").first?.attributes["Algorithm"], let uri = encrypted.descendants("CipherReference").first?.attributes["URI"] else { throw BookError.invalid("EPUB 加密信息不完整") }
            let href = try EPUBPath.resolve(uri).href
            guard let item = items.values.first(where: { $0.href == href }), item.mediaType.hasPrefix("font/") || ["application/vnd.ms-opentype", "application/font-sfnt", "application/font-woff"].contains(item.mediaType) else { throw BookError.invalid("不支持加密正文或 DRM 书籍") }
            let key: [UInt8]; let count: Int
            if algorithm == "http://www.idpf.org/2008/embedding" {
                let normalized = identifier.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(String.init).joined()
                guard !normalized.isEmpty else { throw BookError.invalid("字体混淆缺少书籍标识") }
                key = Array(Insecure.SHA1.hash(data: Data(normalized.utf8))); count = 1040
            } else if algorithm == "http://ns.adobe.com/pdf/enc#RC" {
                let normalized = identifier.replacingOccurrences(of: "urn:uuid:", with: "").replacingOccurrences(of: "-", with: "")
                guard normalized.count == 32 else { throw BookError.invalid("字体混淆标识无效") }
                var bytes: [UInt8] = []
                for offset in stride(from: 0, to: 32, by: 2) { let start = normalized.index(normalized.startIndex, offsetBy: offset); let end = normalized.index(start, offsetBy: 2); guard let byte = UInt8(normalized[start..<end], radix: 16) else { throw BookError.invalid("字体混淆标识无效") }; bytes.append(byte) }
                key = bytes; count = 1024
            } else { throw BookError.invalid("暂不支持 DRM 或非标准加密书籍") }
            let font = try EPUBPath.file(href, in: root)
            var data = try Data(contentsOf: font)
            for index in 0..<min(count, data.count) { data[index] ^= key[index % key.count] }
            try data.write(to: font, options: bookDataWriteOptions)
        }
    }
}
