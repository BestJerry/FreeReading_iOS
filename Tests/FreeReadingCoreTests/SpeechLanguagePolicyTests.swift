import XCTest
@testable import FreeReadingCore

final class SpeechLanguagePolicyTests: XCTestCase {
    func testAllBibliographicAliasesShareTerminologyLanguagePreference() {
        let pairs = ["alb": "sq", "arm": "hy", "baq": "eu", "bur": "my", "chi": "zh", "cze": "cs", "dut": "nl", "fre": "fr", "geo": "ka", "ger": "de", "gre": "el", "ice": "is", "mac": "mk", "mao": "mi", "may": "ms", "per": "fa", "rum": "ro", "slo": "sk", "tib": "bo", "wel": "cy"]
        for (alias, expected) in pairs {
            XCTAssertEqual(SpeechLanguagePolicy.languageKey(alias), expected, alias)
            XCTAssertEqual(SpeechLanguagePolicy.languageKey(alias.uppercased() + "_CN"), expected, alias)
        }
    }

    func testTerminologyCodesOutsideOriginalSmallAliasTable() {
        for (tag, expected) in ["zho": "zh", "eng": "en", "fra": "fr", "deu": "de", "jpn": "ja", "nld": "nl", "sqi": "sq", "hye": "hy", "kat": "ka", "bod": "bo", "mya": "my", "mkd": "mk", "mri": "mi", "msa": "ms", "fas": "fa", "slk": "sk", "cym": "cy", "heb": "he", "yid": "yi", "zul": "zu", "san": "sa", "vol": "vo", "ido": "io", "aar": "aa"] {
            XCTAssertEqual(SpeechLanguagePolicy.languageKey(tag), expected, tag)
        }
    }

    func testEmptyUndAndMalformedBaseUseDeviceLanguageWithScriptAndRegion() {
        for raw in ["", "  ", "und", "UND-CN", "-CN", "_", "123"] {
            let tag = SpeechLanguagePolicy.resolve(raw, fallback: "zh_Hant_TW")
            XCTAssertEqual(tag.language, "zh", raw)
            XCTAssertEqual(tag.script, "Hant", raw)
            XCTAssertEqual(tag.region, "TW", raw)
        }
        XCTAssertEqual(SpeechLanguagePolicy.resolve("und", fallback: "und").language, "en")
    }

    func testFullTagThenScriptAndRegionThenScriptThenRegionOrdering() {
        let requested = "zho_Hant_TW"
        XCTAssertEqual(SpeechLanguagePolicy.matchRank(candidate: "zh-Hant-TW", requested: requested), 8)
        XCTAssertEqual(SpeechLanguagePolicy.matchRank(candidate: "zh-Hant-TW-variant", requested: requested), 6)
        XCTAssertEqual(SpeechLanguagePolicy.matchRank(candidate: "zh-Hant-HK", requested: requested), 4)
        XCTAssertEqual(SpeechLanguagePolicy.matchRank(candidate: "zh-Hans-TW", requested: requested), 2)
        XCTAssertEqual(SpeechLanguagePolicy.matchRank(candidate: "zh-CN", requested: requested), 0)
        XCTAssertEqual(SpeechLanguagePolicy.matchRank(candidate: "en-US", requested: requested), -1)
    }

    func testWhitespaceCaseUnderscoreAndLanguageExtensionsDoNotSplitPreferences() {
        let tag = SpeechLanguagePolicy.resolve("  ZHO_hANT_tw-u-nu-hanidec  ")
        XCTAssertEqual(tag.language, "zh")
        XCTAssertEqual(tag.script, "Hant")
        XCTAssertEqual(tag.region, "TW")
        XCTAssertEqual(tag.identifier, "zh-Hant-TW")
        XCTAssertEqual(SpeechLanguagePolicy.languageKey("deu-DE"), SpeechLanguagePolicy.languageKey("ger-AT"))
        XCTAssertEqual(SpeechLanguagePolicy.languageKey("kok-IN"), "kok") // 无两字母别名的语言不能误回退。
    }
}
