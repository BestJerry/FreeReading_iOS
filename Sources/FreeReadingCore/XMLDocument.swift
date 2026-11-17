import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// 受限 XML 树只用于 OCF、OPF 和 NCX；禁用外部实体并限制嵌套和节点数。
final class EPUBXMLNode {
    let name: String
    let attributes: [String: String]
    var children: [EPUBXMLNode] = []
    enum Content { case text(String), child(EPUBXMLNode) }
    var content: [Content] = []
    init(name: String, attributes: [String: String]) { self.name = name.split(separator: ":").last.map(String.init) ?? name; self.attributes = attributes }
    var text: String { content.map { if case .text(let value) = $0 { return value }; if case .child(let child) = $0 { return child.text }; return "" }.joined() }
    func descendants(_ name: String) -> [EPUBXMLNode] { children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) } }
}

private final class EPUBXMLParser: NSObject, XMLParserDelegate {
    let root = EPUBXMLNode(name: "root", attributes: [:])
    var stack: [EPUBXMLNode] = []
    var count = 0
    var textCount = 0
    var failure: Error?
    override init() { super.init(); stack = [root] }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        count += 1
        guard stack.count < 128, count <= 100_000 else { failure = BookError.invalid("书籍 XML 结构过于复杂"); parser.abortParsing(); return }
        let node = EPUBXMLNode(name: elementName, attributes: attributeDict)
        stack.last?.children.append(node); stack.last?.content.append(.child(node)); stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textCount += string.utf16.count
        guard textCount <= 4 * 1024 * 1024 else { failure = BookError.invalid("书籍 XML 文本过大"); parser.abortParsing(); return }
        stack.last?.content.append(.text(string))
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if stack.count > 1 { stack.removeLast() } }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { failure = BookError.invalid("不支持 XML 自定义实体"); parser.abortParsing() }
}

func readEPUBXML(_ data: Data) throws -> EPUBXMLNode {
    guard data.count <= 8 * 1024 * 1024 else { throw BookError.invalid("书籍 XML 文件过大") }
    let delegate = EPUBXMLParser()
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = false
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    guard parser.parse() else { throw delegate.failure ?? BookError.invalid("EPUB 元数据 XML 损坏") }
    return delegate.root
}
