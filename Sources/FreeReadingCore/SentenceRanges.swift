import Foundation

/// 确定性 UTF-16 分句，与 WebView Range 使用同一坐标，不依赖系统分词版本。
public enum SentenceRanges {
    public static func split(_ text: String, maximumLength: Int = 500) -> [TextRange] {
        precondition(maximumLength >= 2)
        let characters = Array(text.utf16)
        let nsText = text as NSString
        let endings = Set("。！？!?；;\n\r".utf16)
        let closing = Set("\"'”’）)]】》」』〕〉〗〙〛".utf16)
        let soft = Set("，,、：:".utf16)
        var ranges: [TextRange] = []
        var start = 0
        var offset = 0
        var softBreak = 0
        func whitespace(_ value: UInt16) -> Bool { UnicodeScalar(value).map(CharacterSet.whitespacesAndNewlines.contains) ?? false }
        func append(_ end: Int) {
            var first = start; var last = end
            while first < last && whitespace(characters[first]) { first += 1 }
            while last > first && whitespace(characters[last - 1]) { last -= 1 }
            if first < last {
                let slice = nsText.substring(with: NSRange(location: first, length: last - first))
                if slice.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) {
                    ranges.append(TextRange(start: first, end: last))
                }
            }
            start = end; softBreak = end
        }
        while offset < characters.count {
            let value = characters[offset]
            let width = (0xD800...0xDBFF).contains(value) && offset + 1 < characters.count && (0xDC00...0xDFFF).contains(characters[offset + 1]) ? 2 : 1
            if offset + width - start > maximumLength {
                let cut = softBreak > start && softBreak - start >= maximumLength / 2 ? softBreak : offset
                append(cut)
                offset = cut
                continue
            }
            offset += width
            if soft.contains(value) || whitespace(value) { softBreak = offset }
            if endings.contains(value) {
                while offset < characters.count && closing.contains(characters[offset]) && offset - start < maximumLength { offset += 1 }
                append(offset)
            }
        }
        if start < characters.count { append(characters.count) }
        return ranges
    }
}
