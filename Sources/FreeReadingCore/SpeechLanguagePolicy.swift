import Foundation

/// EPUB 语言标签与系统声音使用同一规范；三字母 ISO 639-2 与历史书目别名归到两字母语言。
public enum SpeechLanguagePolicy {
    public struct Tag: Equatable, Sendable {
        public let identifier: String
        public let language: String
        public let script: String?
        public let region: String?
    }

    public static func resolve(_ raw: String, fallback: String = Locale.current.identifier) -> Tag {
        let parsed = parse(raw)
        if parsed.language.isEmpty || parsed.language == "und" {
            let preferred = parse(fallback)
            return preferred.language.isEmpty || preferred.language == "und" ? parse("en") : preferred
        }
        return parsed
    }

    public static func languageKey(_ raw: String, fallback: String = Locale.current.identifier) -> String {
        resolve(raw, fallback: fallback).language
    }

    /// 优先完整标签、书写系统、地区；同一档内由调用方按系统音质与稳定标识排序。
    public static func matchRank(candidate: String, requested: String, fallback: String = Locale.current.identifier) -> Int {
        let desired = resolve(requested, fallback: fallback), actual = resolve(candidate, fallback: fallback)
        guard desired.language == actual.language else { return -1 }
        if desired.identifier == actual.identifier { return 8 }
        let script = desired.script != nil && desired.script == actual.script ? 4 : 0
        let region = desired.region != nil && desired.region == actual.region ? 2 : 0
        return script + region
    }

    private static func parse(_ raw: String) -> Tag {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "@")[0].replacingOccurrences(of: "_", with: "-")
        guard let baseInput = cleaned.split(separator: "-", omittingEmptySubsequences: false).first,
              (2...8).contains(baseInput.count), baseInput.allSatisfy(\.isLetter) else {
            return Tag(identifier: "", language: "", script: nil, region: nil)
        }
        if baseInput.lowercased() == "und" { return Tag(identifier: "und", language: "und", script: nil, region: nil) }
        let canonical = Locale.canonicalLanguageIdentifier(from: cleaned).replacingOccurrences(of: "_", with: "-")
        let parts = canonical.split(separator: "-").map(String.init)
        let base = parts.first?.lowercased() ?? ""
        let language = aliases[base] ?? base
        var script: String?, region: String?
        var rest: [String] = []
        for part in parts.dropFirst() {
            if part.count == 1 { break } // 扩展不是声音语言／地区，不参与排序和偏好键。
            if script == nil && part.count == 4 && part.allSatisfy(\.isLetter) {
                script = part.prefix(1).uppercased() + part.dropFirst().lowercased()
            } else if region == nil && ((part.count == 2 && part.allSatisfy(\.isLetter)) || (part.count == 3 && part.allSatisfy(\.isNumber))) {
                region = part.uppercased()
            } else { rest.append(part.lowercased()) }
        }
        let identifier = ([language] + [script, region].compactMap { $0 } + rest).joined(separator: "-")
        return Tag(identifier: identifier, language: language, script: script, region: region)
    }

    // ISO 639-1 的全部 184 个 ISO 639-2/T 对应项，并包含 20 个 /B 书目别名。
    // 只映射存在两字母对应项的语言；其余有效三字母标签保留原值，避免误归到设备语言。
    private static let aliases: [String: String] = {
        let pairs = """
        aar:aa abk:ab ave:ae afr:af aka:ak amh:am arg:an ara:ar asm:as ava:av aym:ay aze:az
        bak:ba bel:be bul:bg bih:bh bis:bi bam:bm ben:bn bod:bo bre:br bos:bs cat:ca che:ce cha:ch
        cos:co cre:cr ces:cs chu:cu chv:cv cym:cy dan:da deu:de div:dv dzo:dz ewe:ee ell:el eng:en
        epo:eo spa:es est:et eus:eu fas:fa ful:ff fin:fi fij:fj fao:fo fra:fr fry:fy gle:ga gla:gd
        glg:gl grn:gn guj:gu glv:gv hau:ha heb:he hin:hi hmo:ho hrv:hr hat:ht hun:hu hye:hy
        her:hz ina:ia ind:id ile:ie ibo:ig iii:ii ipk:ik ido:io isl:is ita:it iku:iu jpn:ja jav:jv
        kat:ka kon:kg kik:ki kua:kj kaz:kk kal:kl khm:km kan:kn kor:ko kau:kr kas:ks kur:ku
        kom:kv cor:kw kir:ky lat:la ltz:lb lug:lg lim:li lin:ln lao:lo lit:lt lub:lu lav:lv
        mlg:mg mah:mh mri:mi mkd:mk mal:ml mon:mn mar:mr msa:ms mlt:mt mya:my nau:na nob:nb
        nde:nd nep:ne ndo:ng nld:nl nno:nn nor:no nbl:nr nav:nv nya:ny oci:oc oji:oj orm:om
        ori:or oss:os pan:pa pli:pi pol:pl pus:ps por:pt que:qu roh:rm run:rn ron:ro rus:ru
        kin:rw san:sa srd:sc snd:sd sme:se sag:sg sin:si slk:sk slv:sl smo:sm sna:sn som:so
        sqi:sq srp:sr ssw:ss sot:st sun:su swe:sv swa:sw tam:ta tel:te tgk:tg tha:th tir:ti
        tuk:tk tgl:tl tsn:tn ton:to tur:tr tso:ts tat:tt twi:tw tah:ty uig:ug ukr:uk urd:ur
        uzb:uz ven:ve vie:vi vol:vo wln:wa wol:wo xho:xh yid:yi yor:yo zha:za zho:zh zul:zu
        alb:sq arm:hy baq:eu bur:my chi:zh cze:cs dut:nl fre:fr geo:ka ger:de gre:el ice:is
        mac:mk mao:mi may:ms per:fa rum:ro slo:sk tib:bo wel:cy iw:he in:id ji:yi
        """
        return Dictionary(uniqueKeysWithValues: pairs.split(whereSeparator: \.isWhitespace).map { pair in
            let fields = pair.split(separator: ":"); return (String(fields[0]), String(fields[1]))
        })
    }()
}
