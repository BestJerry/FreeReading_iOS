import XCTest
@testable import FreeReadingCore

final class ShareInboxTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testPublishedItemSurvivesMainAppRestartUntilSuccessfullyFinished() throws {
        let root = try temporary()
        let source = root.appendingPathComponent("原创.epub")
        let bytes = Data(repeating: 65, count: 150_000)
        try bytes.write(to: source)
        let inboxURL = root.appendingPathComponent("inbox")
        let inbox = ShareInbox(root: inboxURL)
        let id = try inbox.enqueue(from: source)
        let item = try XCTUnwrap(inbox.claimNext())
        XCTAssertEqual(item.id, id); XCTAssertEqual(item.displayName, "原创.epub")
        XCTAssertEqual(try Data(contentsOf: item.fileURL), bytes)
        let reopened = ShareInbox(root: inboxURL)
        XCTAssertEqual(try reopened.claimNext(), item)
        try reopened.finish(fileURL: item.fileURL)
        XCTAssertNil(try reopened.claimNext())
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testCancelledAndOversizedCopiesNeverPublishPartialFiles() throws {
        let root = try temporary()
        let source = root.appendingPathComponent("book.epub")
        try Data(repeating: 1, count: 100_000).write(to: source)
        let inbox = ShareInbox(root: root.appendingPathComponent("inbox"), maximumBytes: 90_000)
        XCTAssertThrowsError(try inbox.enqueue(from: source))
        XCTAssertNil(try inbox.claimNext())
        XCTAssertThrowsError(try inbox.enqueue(from: source, cancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertNil(try inbox.claimNext())
        let remaining = try FileManager.default.contentsOfDirectory(atPath: inbox.root.path)
        XCTAssertFalse(remaining.contains { $0.hasPrefix(".incoming-") })
    }

    func testMultipleSharesKeepSeparateBytesAndCanOnlyDeleteClaimedFiles() throws {
        let root = try temporary()
        let inbox = ShareInbox(root: root.appendingPathComponent("inbox"))
        for index in 0..<3 {
            let file = root.appendingPathComponent("\(index).epub")
            try Data([UInt8(index)]).write(to: file)
            try inbox.enqueue(from: file)
        }
        var names = Set<String>()
        for _ in 0..<3 {
            let item = try XCTUnwrap(inbox.claimNext())
            names.insert(item.displayName)
            try inbox.finish(fileURL: item.fileURL)
        }
        XCTAssertEqual(names.count, 3)
        XCTAssertNil(try inbox.claimNext())
        let outside = root.appendingPathComponent("keep.epub")
        try Data([1]).write(to: outside)
        XCTAssertThrowsError(try inbox.finish(fileURL: outside))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testMalformedProcessingItemIsIsolatedWithoutBlockingNextShare() throws {
        let root = try temporary()
        let inbox = ShareInbox(root: root.appendingPathComponent("inbox"))
        let invalid = inbox.root.appendingPathComponent("processing/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: invalid.appendingPathComponent("request.json"))
        let source = root.appendingPathComponent("valid.epub")
        try Data([1, 2]).write(to: source)
        try inbox.enqueue(from: source)
        var rejected: [String] = []
        let item = try XCTUnwrap(inbox.claimNext { rejected.append($0) })
        XCTAssertEqual(rejected.count, 1)
        XCTAssertEqual(item.displayName, "valid.epub")
        try inbox.finish(fileURL: item.fileURL)
        XCTAssertNil(try inbox.claimNext())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.root.appendingPathComponent("rejected").path).count, 1)
    }

    func testEPUBProviderCanSupplyTemporaryURLWithoutExtension() throws {
        let root = try temporary()
        let source = root.appendingPathComponent("provider-temporary-file")
        try Data([1, 2, 3]).write(to: source)
        let inbox = ShareInbox(root: root.appendingPathComponent("inbox"))
        XCTAssertThrowsError(try inbox.enqueue(from: source))
        try inbox.enqueue(from: source, displayName: "原创.epub")
        XCTAssertEqual(try inbox.claimNext()?.displayName, "原创.epub")
    }
}
