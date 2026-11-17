import SwiftUI
import UIKit
import ImageIO

/// 书架和播放器共用的封面：有界后台解码，缺图时保留 Android 的书脊与四色占位。
@MainActor
struct BookCoverView: View {
    let title: String
    let url: URL?
    var seed: String = ""
    var prominent = false
    var tint: Color? = nil
    var foreground: Color = .white
    @State private var image: UIImage?
    private var placeholderColor: Color {
        if let tint { return tint }
        // 使用 Java String.hashCode 的 UTF-16 算法，使两端同一本书选择相同占位色。
        var hash: Int32 = 0
        for unit in seed.utf16 { hash = hash &* 31 &+ Int32(unit) }
        let colors: [UInt32] = [0x536D5A, 0x976F55, 0x66747F, 0x88715F]
        return Color(freeReadingHex: colors[Int(UInt32(bitPattern: hash) & 0x7FFF_FFFF) % colors.count])
    }
    var body: some View {
        GeometryReader { size in
            ZStack(alignment: .leading) {
                LinearGradient(colors: [placeholderColor, placeholderColor.opacity(prominent ? 0.75 : 1)], startPoint: .top, endPoint: .bottom)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: size.size.width, height: size.size.height).clipped()
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(prominent ? "FREE READING" : "FR /")
                            .font(.system(size: 8)).tracking(prominent ? 1.4 : 1).opacity(0.65)
                        Spacer(minLength: 4)
                        Text(title).font(.system(size: prominent ? 18 : 13, weight: .regular, design: .serif))
                            .lineSpacing(prominent ? 6 : 3).lineLimit(3)
                        Spacer(minLength: 4)
                        if prominent { Image(systemName: "book.pages").font(.system(size: 23)).opacity(0.7) }
                        else { Rectangle().fill(.white.opacity(0.45)).frame(width: 24, height: 1) }
                    }
                    .foregroundStyle(foreground)
                    .padding(prominent ? 18 : 10)
                    .frame(width: size.size.width, height: size.size.height, alignment: .leading)
                }
                Rectangle().fill(.black.opacity(0.12)).frame(width: prominent ? 6 : 4)
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3,
                                             bottomTrailingRadius: prominent ? 11 : 9, topTrailingRadius: prominent ? 11 : 9))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("《\(title)》封面")
        .task(id: url) {
            image = nil
            let target = url
            let decoded = await Task.detached(priority: .utility) {
                guard let target, let source = CGImageSourceCreateWithURL(target as CFURL, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 800,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) else { return nil as UIImage? }
                return UIImage(cgImage: thumbnail)
            }.value
            guard !Task.isCancelled else { return }
            image = decoded
        }
    }
}
