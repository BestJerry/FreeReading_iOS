import XCTest
import Foundation
import CryptoKit
import ZIPFoundation
@testable import FreeReadingCore

/// 真实 ZIP／XML／HTML 流水线回归，不依赖网络、设备语音引擎或用户个人书籍。
final class BookRepositoryTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FreeReadingTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func repository() throws -> BookRepository { try BookRepository(root: directory.appendingPathComponent("library")) }

    func testOriginalSampleImportsAndReopensWithSharedIndex() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "reading-sample", withExtension: "epub", subdirectory: "Fixtures"))
        let library = try repository()
        let book = try await library.importEPUB(from: source)
        XCTAssertEqual(book.record.title, "山间来信")
        XCTAssertEqual(book.chapters.count, 3)
        XCTAssertEqual(book.contents.count, 3)
        XCTAssertGreaterThan(book.sentences.count, 10)
        let reopened = try await repository().loadBook(id: book.record.id)
        XCTAssertEqual(reopened, book)
        XCTAssertTrue(book.sentences.indices.allSatisfy { !book.text(at: $0).isEmpty })
    }

    func testBOMInlineMarkupAndMixedContainersMatchRawTextOffsets() async throws {
        let source = try fixture(body: "<div>开场。<p id=\"anchor\"> 你好 <b>世界</b>。😀 第二句！\n</p>尾声。</div>", bom: true)
        let library = try repository()
        let book = try await library.importEPUB(from: source)
        XCTAssertEqual(book.sections.map(\.text), ["开场。", " 你好 世界。😀 第二句！\n", "尾声。"])
        XCTAssertEqual(book.sentences.indices.map { book.text(at: $0) }, ["开场。", "你好 世界。", "😀 第二句！", "尾声。"])
        let url = try library.contentURL(bookID: book.record.id, href: book.chapters[0].href)
        let rendered = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(rendered.contains("data-fr-section=\"1\""))
        XCTAssertTrue(rendered.contains("id=\"anchor\""))
        XCTAssertTrue(rendered.contains("<b>世界</b>"))
    }

    func testImportProgressFinishesOnlyAfterFilesAreCommitted() async throws {
        let values = ProgressValues()
        let library = try repository()
        let book = try await library.importEPUB(from: fixture()) { values.append($0) }
        let stages = values.values.map(\.stage)
        XCTAssertTrue(stages.contains(.copying)); XCTAssertTrue(stages.contains(.validating)); XCTAssertTrue(stages.contains(.indexing)); XCTAssertTrue(stages.contains(.saving))
        XCTAssertEqual(stages.last, .completed)
        XCTAssertEqual(values.values.last?.fraction, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.bookDirectory(id: book.record.id).appendingPathComponent("index.json").path))
        let listed = try await library.books()
        XCTAssertEqual(listed.map(\.id), [book.record.id])
    }

    func testDuplicateImportRetainsMetadataAndProgress() async throws {
        let source = try fixture()
        let library = try repository()
        let first = try await library.importEPUB(from: source)
        let saved = ReadingProgress(bookID: first.record.id, sentenceIndex: 1, audioOffset: 1.25)
        try await library.saveProgress(saved)
        let duplicate = try await library.importEPUB(from: source)
        XCTAssertEqual(duplicate, first)
        let progress = try await library.readingProgress(bookID: first.record.id)
        XCTAssertEqual(progress, saved)
        let listed = try await library.books()
        XCTAssertEqual(listed.count, 1)
    }

    func testNewerProgressWinsAndInvalidValuesAreIgnored() async throws {
        let library = try repository()
        let book = try await library.importEPUB(from: fixture())
        let newer = ReadingProgress(bookID: book.record.id, sentenceIndex: 1, audioOffset: 2, updatedAt: Date().addingTimeInterval(2))
        try await library.saveProgress(newer)
        try await library.saveProgress(ReadingProgress(bookID: book.record.id, audioOffset: 0, updatedAt: Date()))
        try await library.saveProgress(ReadingProgress(bookID: book.record.id, audioOffset: .nan, updatedAt: Date().addingTimeInterval(3)))
        try await library.saveProgress(ReadingProgress(bookID: book.record.id, sentenceIndex: 10_000, updatedAt: Date().addingTimeInterval(4)))
        let result = try await library.readingProgress(bookID: book.record.id)
        XCTAssertEqual(result, newer)
    }

    func testDeleteAndReimportRejectsPreviousImportSave() async throws {
        let library = try repository()
        let source = try fixture()
        let first = try await library.importEPUB(from: source)
        try await library.removeBook(id: first.record.id)
        try await library.saveProgress(ReadingProgress(bookID: first.record.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.bookDirectory(id: first.record.id).path))
        let second = try await library.importEPUB(from: source)
        XCTAssertNotEqual(first.record.addedAt, second.record.addedAt)
        try await library.saveProgress(ReadingProgress(bookID: second.record.id, audioOffset: 3), expectedAddedAt: first.record.addedAt)
        let stale = try await library.readingProgress(bookID: second.record.id)
        XCTAssertNil(stale)
        let fresh = ReadingProgress(bookID: second.record.id, audioOffset: 1)
        try await library.saveProgress(fresh, expectedAddedAt: second.record.addedAt)
        let stored = try await library.readingProgress(bookID: second.record.id)
        XCTAssertEqual(stored, fresh)
    }

    func testEPUB3NestedContentsKeepFragmentsAndSkipExternalLinks() async throws {
        let nav = "<nav epub:type=\"toc\"><ol><li><a href=\"chapter.xhtml#anchor\">标题</a><ol><li><a href=\"chapter.xhtml#child\">子节</a></li></ol></li><li><a href=\"https://example.com\">外链</a></li></ol></nav>"
        let book = try await repository().importEPUB(from: fixture(nav: nav))
        XCTAssertEqual(book.contents.map(\.title), ["标题", "子节"])
        XCTAssertEqual(book.contents.map(\.depth), [0, 1])
        XCTAssertEqual(book.contents.map(\.fragment), ["anchor", "child"])
        XCTAssertEqual(book.chapters[0].title, "标题")
    }

    func testEPUB2NCXContentsAreSupported() async throws {
        let ncx = "<ncx><navMap><navPoint id=\"p1\"><navLabel><text>第一章</text></navLabel><content src=\"chapter.xhtml#a\"/><navPoint id=\"p2\"><navLabel><text>子节</text></navLabel><content src=\"chapter.xhtml#b\"/></navPoint></navPoint></navMap></ncx>"
        let book = try await repository().importEPUB(from: fixture(ncx: ncx))
        XCTAssertEqual(book.contents.map(\.title), ["第一章", "子节"])
        XCTAssertEqual(book.contents.map(\.depth), [0, 1])
    }

    func testDeepContentsAreRejectedBeforePublishingAnUnreadableIndex() async throws {
        let nav = "<nav epub:type=\"toc\">" + String(repeating: "<ol><li>", count: 130) + "<a href=\"chapter.xhtml#anchor\">过深目录</a>" + String(repeating: "</li></ol>", count: 130) + "</nav>"
        await expectFailure(try fixture(nav: nav))
        let books = try await repository().books()
        XCTAssertTrue(books.isEmpty)
    }

    func testScriptsHandlersRefreshAndForgedSectionsAreRemoved() async throws {
        let body = "<script>alert(1)</script><p data-fr-section=\"999\" onclick=\"alert(1)\">正文。<a href=\"java&#10;script:alert(1)\">链接</a></p><iframe src=\"https://example.com\"></iframe><meta http-equiv=\"Refresh\" content=\"1;url=https://example.com\"/>"
        let library = try repository(); let book = try await library.importEPUB(from: fixture(body: body))
        let html = try String(contentsOf: library.contentURL(bookID: book.record.id, href: book.chapters[0].href), encoding: .utf8)
        XCTAssertFalse(html.contains("alert(1)")); XCTAssertFalse(html.contains("iframe")); XCTAssertFalse(html.contains("Refresh")); XCTAssertFalse(html.contains("999"))
        XCTAssertTrue(html.contains("data-fr-section=\"0\""))
    }

    func testStandardFontObfuscationIsDecoded() async throws {
        let original = Data((0..<1200).map { UInt8($0 % 251) })
        let key = Array(Insecure.SHA1.hash(data: Data("urn:uuid:12345678-1234-1234-1234-123456789abc".utf8)))
        var scrambled = original
        for i in 0..<1040 { scrambled[i] ^= key[i % key.count] }
        let encryption = "<encryption><EncryptedData><EncryptionMethod Algorithm=\"http://www.idpf.org/2008/embedding\"/><CipherData><CipherReference URI=\"OPS/font.ttf\"/></CipherData></EncryptedData></encryption>"
        let source = try fixture(manifestExtra: "<item id=\"font\" href=\"font.ttf\" media-type=\"font/ttf\"/>", extras: [("OPS/font.ttf", scrambled, .file), ("META-INF/encryption.xml", Data(encryption.utf8), .file)])
        let library = try repository(); let book = try await library.importEPUB(from: source)
        let decoded = try Data(contentsOf: library.contentURL(bookID: book.record.id, href: "OPS/font.ttf"))
        XCTAssertEqual(decoded, original)
    }

    func testUnsafeArchivesFailWithoutPublishingOrLeavingStaging() async throws {
        for extra in [("../outside", Data("逃逸".utf8), Entry.EntryType.file), ("OPS/link", Data("../../outside".utf8), .symlink), ("OPS/CHAPTER.XHTML", Data("碰撞".utf8), .file)] {
            let source = try fixture(extras: [extra])
            await expectFailure(source)
        }
        let children = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("library/books").path)
        XCTAssertTrue(children.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("outside").path))
    }

    func testFixedLayoutDRMAndExternalSpineAreRejected() async throws {
        await expectFailure(try fixture(metadataExtra: "<meta property=\"rendition:layout\">pre-paginated</meta>"))
        await expectFailure(try fixture(extras: [("META-INF/rights.xml", Data("<rights/>".utf8), .file)]))
        await expectFailure(try fixture(chapterHref: "https://example.com/book.xhtml"))
    }

    func testCRCFailureDoesNotCreateShelfEntry() async throws {
        let source = try fixture()
        var data = try Data(contentsOf: source)
        let sequence = Data("application/epub+zip".utf8)
        let range = try XCTUnwrap(data.range(of: sequence))
        data[range.lowerBound] = Character("z").asciiValue!
        try data.write(to: source)
        await expectFailure(source)
    }

    func testCancelledImportCleansTemporaryFiles() async throws {
        let library = try repository(); let source = try fixture()
        let task = Task {
            try await library.importEPUB(from: source) { value in
                if value.stage == .copying { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        switch await task.result {
        case .success: XCTFail("Cancelled import succeeded")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        let listed = try await library.books()
        XCTAssertTrue(listed.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("library/books").path).isEmpty)
    }

    func testCorruptIndexIsRejectedAndInvalidBookIDCannotEscape() async throws {
        let library = try repository(); let book = try await library.importEPUB(from: fixture())
        var corrupt = book; corrupt.sentences[0].range.end = Int.max
        let data = try JSONEncoder().encode(corrupt)
        try data.write(to: library.bookDirectory(id: book.record.id).appendingPathComponent("index.json"))
        do { _ = try await repository().loadBook(id: book.record.id); XCTFail("Corrupt index accepted") } catch {}
        XCTAssertThrowsError(try library.contentURL(bookID: "../outside", href: "chapter.xhtml"))
    }

    func testEmptyAndImageOnlyBooksAreRejected() async throws {
        let empty = directory.appendingPathComponent("empty.epub"); try Data().write(to: empty)
        await expectFailure(empty)
        await expectFailure(try fixture(body: "<img src=\"cover.png\"/>"))
    }

    func testMetadataOpeningDoesNotReadDamagedSpeechIndex() async throws {
        let library = try repository(); let book = try await library.importEPUB(from: fixture())
        let bookDirectory = library.bookDirectory(id: book.record.id)
        try Data("broken".utf8).write(to: bookDirectory.appendingPathComponent("index.json"))
        try FileManager.default.removeItem(at: bookDirectory.appendingPathComponent("sections.jsonl"))
        let cold = try repository()
        let bootstrap = try await cold.prepareReadingBook(id: book.record.id)
        XCTAssertEqual(bootstrap.book, ReadingBook(book: book))
        XCTAssertNil(bootstrap.cachedSpeechBook)
        do { _ = try await cold.loadSpeechBook(id: book.record.id); XCTFail("Damaged speech accepted") } catch {}
    }

    func testLegacyBookGetsLightCatalogThenMigratesWithoutReimport() async throws {
        let library = try repository(); let book = try await library.importEPUB(from: fixture())
        let folder = library.bookDirectory(id: book.record.id)
        try JSONEncoder().encode(book).write(to: folder.appendingPathComponent("index.json"))
        for file in ["reading.json", "sections.jsonl", "sentences.jsonl"] { try FileManager.default.removeItem(at: folder.appendingPathComponent(file)) }
        let cold = try repository()
        let bootstrap = try await cold.prepareReadingBook(id: book.record.id)
        XCTAssertEqual(bootstrap.book, ReadingBook(book: book))
        XCTAssertNil(bootstrap.cachedSpeechBook)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("sentences.jsonl").path))
        let loaded = try await cold.loadSpeechBook(id: book.record.id)
        XCTAssertEqual(loaded, book)
        let header = try BookIndexIO.readJSON(BookIndexIO.Header.self, from: folder.appendingPathComponent("index.json"), limit: 16384)
        XCTAssertEqual(header.version, 2)
        let reopened = try await repository().loadBook(id: book.record.id)
        XCTAssertEqual(reopened, book)
    }

    func testLegacyCacheWriteFailureStillAllowsReadingAndListeningThenRetries() async throws {
        let library = try repository(); let book = try await library.importEPUB(from: fixture())
        let folder = library.bookDirectory(id: book.record.id)
        try JSONEncoder().encode(book).write(to: folder.appendingPathComponent("index.json"))
        for file in ["reading.json", "sections.jsonl", "sentences.jsonl"] { try FileManager.default.removeItem(at: folder.appendingPathComponent(file)) }
        do {
            // 在普通 macOS 用户下真正拒绝目录中新建/原子替换文件；root CI 不能靠 mode 注入此故障。
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
            try XCTSkipIf(FileManager.default.isWritableFile(atPath: folder.path), "当前用户不受 POSIX 目录只读权限约束")
            let cold = try repository()
            let bootstrap = try await cold.prepareReadingBook(id: book.record.id)
            XCTAssertEqual(bootstrap.book, ReadingBook(book: book))
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("reading.json").path))
            let playable = try await cold.loadSpeechBook(id: book.record.id)
            XCTAssertEqual(playable, book)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("sentences.jsonl").path))
        }
        // 恢复写入能力后的下一次冷加载继续完成迁移，不需要重新导入 EPUB。
        let retried = try await repository().loadSpeechBook(id: book.record.id)
        XCTAssertEqual(retried, book)
        let header = try BookIndexIO.readJSON(BookIndexIO.Header.self, from: folder.appendingPathComponent("index.json"), limit: 16384)
        XCTAssertEqual(header.version, 2)
    }

    func testFinalReadingSaveWaitsOnReopenButCanLoadSpeechItself() async throws {
        let original = try repository(); let book = try await original.importEPUB(from: fixture())
        let cold = try repository(); let gate = StorageTestGate()
        let saved = ReadingProgress(bookID: book.record.id, sentenceIndex: 1, audioOffset: 2.4)
        let save = Task {
            await gate.wait()
            _ = try? await cold.loadSpeechBook(id: book.record.id)
            try? await cold.saveProgress(saved, expectedAddedAt: book.record.addedAt)
        }
        cold.registerReadingSave(bookID: book.record.id, expectedAddedAt: book.record.addedAt, task: save)
        let finished = expectation(description: "Light opener waits for fresh final position")
        let flag = StorageTestFlag()
        let opener = Task { () throws -> ReadingBookBootstrap in
            let result = try await cold.prepareReadingBook(id: book.record.id)
            flag.mark(); finished.fulfill(); return result
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(flag.value)
        await gate.open()
        await fulfillment(of: [finished], timeout: 3)
        guard flag.value else { opener.cancel(); return }
        let bootstrap = try await opener.value
        XCTAssertEqual(bootstrap.progress, saved)
    }

    func testProgressWriteFailureKeepsMemoryPositionAndRetries() async throws {
        let library = try repository(); let book = try await library.importEPUB(from: fixture())
        let progressURL = library.bookDirectory(id: book.record.id).appendingPathComponent("progress.json")
        try FileManager.default.createDirectory(at: progressURL, withIntermediateDirectories: true)
        let saved = ReadingProgress(bookID: book.record.id, sentenceIndex: 1, audioOffset: 4)
        do { try await library.saveProgress(saved, expectedAddedAt: book.record.addedAt); XCTFail("Injected disk error was hidden") } catch {}
        let memory = try await library.readingProgress(bookID: book.record.id)
        XCTAssertEqual(memory, saved)
        try FileManager.default.removeItem(at: progressURL)
        let retried = try await library.readingProgress(bookID: book.record.id)
        XCTAssertEqual(retried, saved)
        let disk = try await repository().readingProgress(bookID: book.record.id)
        XCTAssertEqual(disk, saved)
    }

    func testOldFinalSaveCannotBlockOrOverwriteReimport() async throws {
        let library = try repository(); let source = try fixture(); let first = try await library.importEPUB(from: source)
        let gate = StorageTestGate()
        let oldSave = Task {
            await gate.wait()
            try? await library.saveProgress(ReadingProgress(bookID: first.record.id, audioOffset: 5), expectedAddedAt: first.record.addedAt)
        }
        library.registerReadingSave(bookID: first.record.id, expectedAddedAt: first.record.addedAt, task: oldSave)
        try await library.removeBook(id: first.record.id)
        let second = try await library.importEPUB(from: source)
        let fresh = try await library.prepareReadingBook(id: second.record.id)
        XCTAssertNil(fresh.progress)
        await gate.open(); await oldSave.value
        let result = try await library.readingProgress(bookID: second.record.id)
        XCTAssertNil(result)
    }

    func testImportWorkerDoesNotBlockProgressOrLoseActiveStagingToAnotherInstance() async throws {
        let library = try repository(); let first = try await library.importEPUB(from: fixture())
        let source = try fixture(body: "<p>另一本正文。第二句。</p>")
        let entered = expectation(description: "Heavy worker reached indexing")
        let block = StorageTestBlockingStage()
        let importer = Task {
            try await library.importEPUB(from: source) { progress in
                if progress.stage == .indexing, block.claim() { entered.fulfill(); block.wait() }
            }
        }
        defer { block.release() }
        await fulfillment(of: [entered], timeout: 3)
        _ = try repository() // 初始化另一个实例不能清走正在使用的 .import 目录。
        let active = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("library/books").path)
        XCTAssertEqual(active.filter { $0.hasPrefix(".import-") }.count, 1)
        let saved = ReadingProgress(bookID: first.record.id, audioOffset: 1)
        let stored = expectation(description: "Progress actor remains available")
        let save = Task { try await library.saveProgress(saved); stored.fulfill() }
        await fulfillment(of: [stored], timeout: 1)
        block.release()
        _ = try await importer.value; try await save.value
        let result = try await library.readingProgress(bookID: first.record.id)
        XCTAssertEqual(result, saved)
    }

    func testQueuedImportCancellationAndActiveImportCancellationCleanStaging() async throws {
        let library = try repository(); let source = try fixture()
        let entered = expectation(description: "Active import entered indexing")
        let block = StorageTestBlockingStage()
        let first = Task {
            try await library.importEPUB(from: source) { progress in
                if progress.stage == .indexing, block.claim() { entered.fulfill(); block.wait() }
            }
        }
        defer { block.release() }
        await fulfillment(of: [entered], timeout: 3)
        let second = Task { try await library.importEPUB(from: source) }
        second.cancel()
        switch await second.result {
        case .success: XCTFail("Queued cancellation ignored")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        first.cancel(); block.release()
        switch await first.result {
        case .success: XCTFail("Active cancellation ignored")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("library/books").path)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testStartupRecoversAbandonedTemporaryDirectoriesOnly() throws {
        let root = directory.appendingPathComponent("library")
        for path in ["books/.import-crashed", ".trash-crashed", "books/keep-me", "keep-me"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        _ = try repository()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("books/.import-crashed").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".trash-crashed").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("books/keep-me").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("keep-me").path))
    }

    func testRTLSpineIsPreservedAndLegacyMetadataDefaultsToLTR() async throws {
        let library = try repository()
        let book = try await library.importEPUB(from: fixture(spineAttributes: "page-progression-direction=\"rtl\""))
        XCTAssertEqual(book.record.readingDirection, .rightToLeft)
        let reopened = try await repository().prepareReadingBook(id: book.record.id)
        XCTAssertEqual(reopened.book.readingDirection, .rightToLeft)
        var legacy = book; legacy.record.readingDirection = nil
        let data = try JSONEncoder().encode(legacy.record)
        let decoded = try JSONDecoder().decode(BookRecord.self, from: data)
        legacy.record = decoded
        XCTAssertEqual(ReadingBook(book: legacy).readingDirection, .leftToRight)
    }

    private func expectFailure(_ source: URL, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await repository().importEPUB(from: source); XCTFail("Invalid EPUB accepted", file: file, line: line) } catch {}
    }

    /// 原创最小 EPUB，允许单项故障注入；ZIP 使用公开 provider API，不依赖命令行 zip。
    private func fixture(body: String = "<h1 id=\"anchor\">标题</h1><p>第一句。第二句！</p>", nav: String? = nil, ncx: String? = nil, bom: Bool = false, metadataExtra: String = "", manifestExtra: String = "", chapterHref: String = "chapter.xhtml", spineAttributes: String = "", extras: [(String, Data, Entry.EntryType)] = []) throws -> URL {
        let source = directory.appendingPathComponent(UUID().uuidString + ".epub")
        let archive = try Archive(url: source, accessMode: .create)
        let navItem = ncx == nil ? "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>" : "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>"
        let opf = "<package version=\"3.0\" unique-identifier=\"uid\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"uid\">urn:uuid:12345678-1234-1234-1234-123456789abc</dc:identifier><dc:title>原创测试书</dc:title><dc:creator>FreeReading</dc:creator><dc:language>zh-CN</dc:language>\(metadataExtra)</metadata><manifest><item id=\"chapter\" href=\"\(chapterHref)\" media-type=\"application/xhtml+xml\"/>\(navItem)\(manifestExtra)</manifest><spine toc=\"ncx\" \(spineAttributes)><itemref idref=\"chapter\"/></spine></package>"
        let html = "<!DOCTYPE html><html><head><title>测试</title></head><body>\(body)</body></html>"
        var chapter = Data(html.utf8); if bom { chapter = Data([0xEF, 0xBB, 0xBF]) + chapter }
        var entries: [(String, Data, Entry.EntryType)] = [
            ("mimetype", Data("application/epub+zip".utf8), .file),
            ("META-INF/container.xml", Data("<container><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8), .file),
            ("OPS/package.opf", Data(opf.utf8), .file),
            ("OPS/chapter.xhtml", chapter, .file)
        ]
        if let ncx { entries.append(("OPS/toc.ncx", Data(ncx.utf8), .file)) }
        else { entries.append(("OPS/nav.xhtml", Data("<html><body>\(nav ?? "<nav epub:type=\"toc\"><ol><li><a href=\"chapter.xhtml#anchor\">第一章</a></li></ol></nav>")</body></html>".utf8), .file)) }
        entries += extras
        for (path, data, type) in entries {
            try archive.addEntry(with: path, type: type, uncompressedSize: Int64(data.count)) { position, count in
                let start = Int(position); return data.subdata(in: start..<min(start + count, data.count))
            }
        }
        return source
    }
}

/// 测试显式控制并发次序，避免用整本长书的耗时偶然性判断 actor 是否被阻塞。
private actor StorageTestGate {
    private var isOpen = false
    private var pending: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !isOpen { await withCheckedContinuation { pending.append($0) } } }
    func open() { isOpen = true; let values = pending; pending.removeAll(); values.forEach { $0.resume() } }
}
private final class StorageTestFlag: @unchecked Sendable {
    private let lock = NSLock(); private var completed = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return completed }
    func mark() { lock.lock(); completed = true; lock.unlock() }
}
private final class StorageTestBlockingStage: @unchecked Sendable {
    private let lock = NSLock(); private var claimed = false
    private let semaphore = DispatchSemaphore(value: 0)
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if claimed { return false }; claimed = true; return true }
    func wait() { semaphore.wait() }
    func release() { semaphore.signal() }
}

private final class ProgressValues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ImportProgress] = []
    var values: [ImportProgress] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: ImportProgress) { lock.lock(); storage.append(value); lock.unlock() }
}
