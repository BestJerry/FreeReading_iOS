import Foundation

/// 分享扩展只复制原始 EPUB；主应用下次前台运行时完成校验、索引和入库。
/// 每项先写临时目录再原子发布，主应用不会读到尚未复制完的文件。
public struct ShareInbox: Sendable {
    public let root: URL
    public let maximumBytes: Int64
    public init(root: URL, maximumBytes: Int64 = 100 * 1024 * 1024) {
        self.root = root; self.maximumBytes = maximumBytes
    }
    public struct Item: Equatable, Sendable {
        public let id: UUID
        public let fileURL: URL
        public let displayName: String
    }
    private struct Manifest: Codable { let id: UUID; let displayName: String; let createdAt: Date }
    public enum InboxError: LocalizedError {
        case tooLarge, invalidFile, corruptItem
        public var errorDescription: String? {
            switch self {
            case .tooLarge: return "EPUB 超过 100 MiB，无法通过分享导入。"
            case .invalidFile: return "请选择一个可读取的 EPUB 文件。"
            case .corruptItem: return "分享文件已损坏，请重新分享。"
            }
        }
    }

    /// 提供方临时 URL 仅在回调期间有效，必须在回调返回前完成此有界复制。
    @discardableResult
    public func enqueue(from url: URL, displayName: String? = nil, cancelled: @Sendable () -> Bool = { false }) throws -> UUID {
        let epubName = (displayName as NSString?)?.pathExtension.lowercased() == "epub"
        guard url.isFileURL, url.pathExtension.lowercased() == "epub" || epubName else { throw InboxError.invalidFile }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw InboxError.invalidFile }
        try prepareDirectories()
        let id = UUID()
        let staging = root.appendingPathComponent(".incoming-\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let destination = staging.appendingPathComponent("book.epub")
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw InboxError.invalidFile }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var copied: Int64 = 0
        while true {
            if cancelled() { throw CancellationError() }
            guard let data = try input.read(upToCount: 64 * 1024), !data.isEmpty else { break }
            guard copied <= maximumBytes - Int64(data.count) else { throw InboxError.tooLarge }
            copied += Int64(data.count)
            try output.write(contentsOf: data)
        }
        guard copied > 0 else { throw InboxError.invalidFile }
        try output.synchronize()
        if cancelled() { throw CancellationError() }
        let manifest = Manifest(id: id, displayName: String((displayName ?? url.lastPathComponent).prefix(255)), createdAt: Date())
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("request.json"), options: .atomic)
        try FileManager.default.moveItem(at: staging, to: root.appendingPathComponent("pending/\(id.uuidString)", isDirectory: true))
        return id
    }

    /// 处理中的项目在硬退出后仍可恢复。仅主应用调用 claim，扩展只写 pending。
    public func claimNext(onRejected: (String) -> Void = { _ in }) throws -> Item? {
        try prepareDirectories()
        for location in ["processing", "pending"] {
            let parent = root.appendingPathComponent(location, isDirectory: true)
            let directories = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for directory in directories {
                guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
                let target = root.appendingPathComponent("processing/\(id.uuidString)", isDirectory: true)
                if location == "pending" { try FileManager.default.moveItem(at: directory, to: target) }
                do {
                    let manifestURL = target.appendingPathComponent("request.json")
                    guard (try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 64 * 1024 else { throw InboxError.corruptItem }
                    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
                    let file = target.appendingPathComponent("book.epub")
                    guard manifest.id == id, FileManager.default.fileExists(atPath: file.path) else { throw InboxError.corruptItem }
                    return Item(id: id, fileURL: file, displayName: manifest.displayName)
                } catch {
                    let rejected = root.appendingPathComponent("rejected", isDirectory: true)
                    try FileManager.default.createDirectory(at: rejected, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: target, to: rejected.appendingPathComponent(UUID().uuidString))
                    onRejected(id.uuidString)
                    // 单份坏文件不应阻塞之后分享的正常书籍。
                }
            }
        }
        return nil
    }

    /// 成功或用户取消后清理；失败保留供重试。只接受规范的 processing 路径。
    public func finish(fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        guard fileURL.lastPathComponent == "book.epub", UUID(uuidString: directory.lastPathComponent) != nil,
              directory.deletingLastPathComponent().standardizedFileURL == root.appendingPathComponent("processing").standardizedFileURL else { throw InboxError.invalidFile }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private func prepareDirectories() throws {
        for name in ["pending", "processing"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        // 仅回收一天前遗留的未发布复制，正常进行中的其他扩展会话不会被清理。
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
            where url.lastPathComponent.hasPrefix(".incoming-") {
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
