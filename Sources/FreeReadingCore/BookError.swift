import Foundation

/// 可直接向用户呈现的书库错误；底层读取失败仍保留系统错误说明。
public enum BookError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

/// EPUB 容量边界，导入和重新读取索引共用，防止异常文件无限占用内存或磁盘。
public enum BookLimits {
    public static let sourceBytes: Int64 = 100 * 1024 * 1024
    public static let expandedBytes: UInt64 = 512 * 1024 * 1024
    public static let resourceBytes: UInt64 = 32 * 1024 * 1024
    public static let indexBytes = 128 * 1024 * 1024
    public static let textCharacters = 20_000_000
    public static let sentences = 500_000
    public static let resources = 20_000
}

/// 首次解锁后锁屏仍可读写本地音频配套数据；macOS 单测只使用普通原子写入。
var bookDataWriteOptions: Data.WritingOptions {
    #if os(iOS)
    return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    #else
    return [.atomic]
    #endif
}

/// 将 EPUB 中的相对资源地址限制在解压目录内，编码的路径也必须通过相同检查。
public enum EPUBPath {
    public static func resolve(_ reference: String, relativeTo document: String = "") throws -> (href: String, fragment: String?) {
        guard reference.utf8.count <= 4096, !reference.contains("\\"), !reference.contains("\0") else {
            throw BookError.invalid("书籍包含无效资源路径")
        }
        let pieces = reference.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(pieces[0].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        guard !rawPath.hasPrefix("/"), URLComponents(string: rawPath)?.scheme == nil,
              let decoded = rawPath.removingPercentEncoding, !decoded.hasPrefix("/"), !decoded.contains("\\"), !decoded.contains("\0") else {
            throw BookError.invalid("不支持外部正文资源或越界路径")
        }
        var parts = rawPath.isEmpty ? document.split(separator: "/").map(String.init)
            : document.split(separator: "/").dropLast().map(String.init)
        if !rawPath.isEmpty {
            for part in decoded.split(separator: "/", omittingEmptySubsequences: false) {
                if part.isEmpty || part == "." { continue }
                if part == ".." {
                    guard !parts.isEmpty else { throw BookError.invalid("书籍资源路径越出容器") }
                    parts.removeLast()
                } else {
                    guard !part.contains(":"), part.utf8.count <= 255 else { throw BookError.invalid("书籍资源路径无效") }
                    parts.append(String(part))
                }
            }
        }
        guard !parts.isEmpty else { throw BookError.invalid("书籍资源路径为空") }
        let fragment = pieces.count == 2 ? String(pieces[1]).removingPercentEncoding : nil
        return (parts.joined(separator: "/"), fragment?.isEmpty == false ? fragment : nil)
    }

    /// ZIP 文件名不做 URL 解码；所有绝对路径、上级跳转及平台分隔符均拒绝。
    static func archivePath(_ path: String) throws -> String {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !path.contains("\0") else {
            throw BookError.invalid("EPUB 压缩包包含不安全路径")
        }
        let parts = path.split(separator: "/")
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." || $0.utf8.count > 255 }) else {
            throw BookError.invalid("EPUB 压缩包包含越界路径")
        }
        return parts.joined(separator: "/")
    }

    static func file(_ href: String, in root: URL) throws -> URL {
        let normalized = try archivePath(href)
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let file = base.appendingPathComponent(normalized).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(base.path + "/") else { throw BookError.invalid("资源位于书籍目录之外") }
        return file
    }
}
