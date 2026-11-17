import SwiftUI

/// 与 Android Theme.kt 共用的书架色板；阅读纸色由 ReadingColors 单独管理。
enum LibraryTheme {
    static let paper = Color(freeReadingHex: 0xF7F5EF)
    static let ink = Color(freeReadingHex: 0x282D29)
    static let forest = Color(freeReadingHex: 0x456454)
    static let muted = Color(freeReadingHex: 0x74796F)
    static let surfaceVariant = Color(freeReadingHex: 0xEDEBE3)
    static let outline = Color(freeReadingHex: 0xD5D8CD)
    static let card = Color(freeReadingHex: 0xEFEEE7)
    static let badge = Color(freeReadingHex: 0xE9EDDF)
    static let brown = Color(freeReadingHex: 0x9E7250)
}

/// 原文、目录、设置和听书共用同一组颜色，切到夜读后不出现浅色弹层。
struct ReadingColors: Equatable {
    let theme: String
    var isNight: Bool { theme == "night" || theme == "dark" }
    private var paperValue: UInt32 { isNight ? 0x1E2422 : theme == "white" ? 0xFCFCF9 : 0xF7F2E8 }
    private var inkValue: UInt32 { isNight ? 0xE4E9E3 : 0x293C35 }
    var paper: Color { Color(freeReadingHex: paperValue) }
    var ink: Color { Color(freeReadingHex: inkValue) }
    var accent: Color { Color(freeReadingHex: isNight ? 0xB5CDB5 : 0x49674F) }
    var muted: Color { ink.opacity(0.62) }
    var paperHex: String { String(format: "#%06X", paperValue) }
    var inkHex: String { String(format: "#%06X", inkValue) }
}

/// 兼容使用默认阅读色板的辅助控件；有主题状态的页面应使用 ReadingColors。
enum ReaderPalette {
    static let paper = ReadingColors(theme: "paper").paper
    static let ink = ReadingColors(theme: "paper").ink
    static let forest = ReadingColors(theme: "paper").accent
}

extension Color {
    init(freeReadingHex value: UInt32) {
        self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255, opacity: 1)
    }
}
