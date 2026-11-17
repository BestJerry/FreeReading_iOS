import XCTest
@testable import FreeReadingCore

final class SentenceRangesTests: XCTestCase {
    func testChinesePunctuationWhitespaceAndClosingQuotes() {
        let text = "  第一行。 “第二句！”\n第三句？  "
        let parts = SentenceRanges.split(text).map { (text as NSString).substring(with: NSRange(location: $0.start, length: $0.end - $0.start)) }
        XCTAssertEqual(parts, ["第一行。", "“第二句！”", "第三句？"])
    }

    func testPunctuationOnlyIsNotSpoken() { XCTAssertEqual(SentenceRanges.split("  。！？…… 🎵  "), []) }

    func testLongTextDoesNotSplitSurrogatePairs() {
        let text = String(repeating: "😀文字", count: 400)
        let ranges = SentenceRanges.split(text, maximumLength: 17)
        let recovered = ranges.map { (text as NSString).substring(with: NSRange(location: $0.start, length: $0.end - $0.start)) }
        XCTAssertTrue(ranges.allSatisfy { $0.end - $0.start <= 17 })
        XCTAssertEqual(recovered.joined(), text)
        XCTAssertFalse(recovered.joined().contains("\u{FFFD}"))
    }

    func testSoftBreakPrefersTheSecondHalf() {
        let text = "甲乙丙丁，戊己庚辛，壬癸子丑寅卯辰巳午未"
        let first = SentenceRanges.split(text, maximumLength: 12).first
        XCTAssertEqual(first?.end, 10)
    }

    func testRepeatedSentencesHaveDistinctRanges() {
        XCTAssertEqual(SentenceRanges.split("重复。重复。"), [TextRange(start: 0, end: 3), TextRange(start: 3, end: 6)])
    }

    func testLongSharedParagraphRemainsBounded() {
        let text = String(repeating: "短句。", count: 30_000)
        let ranges = SentenceRanges.split(text)
        XCTAssertEqual(ranges.count, 30_000)
        XCTAssertEqual(ranges.last?.end, text.utf16.count)
    }

    func testSafeRelativeResourceAndDecodedFragment() throws {
        let address = try EPUBPath.resolve("../Images/a%20b.png#%E7%AC%AC%E4%B8%80%E7%AB%A0", relativeTo: "OPS/Text/ch.xhtml")
        XCTAssertEqual(address.href, "OPS/Images/a b.png")
        XCTAssertEqual(address.fragment, "第一章")
        XCTAssertEqual(try EPUBPath.resolve("#start", relativeTo: "OPS/ch.xhtml").href, "OPS/ch.xhtml")
    }

    func testUnsafeResourcePathsAreRejected() {
        for path in ["../../outside", "%2e%2e/secret", "https://example.com/a", "//server/a", "/absolute", "%2Fabsolute", "a\\b", "x%00y", "a%ZZ", "file:a"] {
            XCTAssertThrowsError(try EPUBPath.resolve(path), path)
        }
    }

    func testXMLPreservesMixedTextOrderAndRejectsEntityExpansion() throws {
        let tree = try readEPUBXML(Data("<root><label>甲<b>乙</b>丙</label></root>".utf8))
        XCTAssertEqual(tree.descendants("label").first?.text, "甲乙丙")
        XCTAssertThrowsError(try readEPUBXML(Data("<!DOCTYPE root [<!ENTITY e '展开'>]><root>&e;</root>".utf8)))
    }
}
