import XCTest
import Foundation
import SQLite3
@testable import ClipboardKit

final class SharedClipboardStoreTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("clippy-sharing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func store() throws -> SharedClipboardStore { try SharedClipboardStore(directory: root.appendingPathComponent("shared")) }

    func testBothAppsCombineDeduplicateAndObserveDeletes() throws {
        let clippy = try store(), coworker = try store()
        try clippy.register(client: "clippy")
        try coworker.register(client: "coworker")
        XCTAssertTrue(try clippy.hasClient("coworker"))
        try clippy.upsert(.fromText("one", source: "Clippy"))
        let first = try clippy.snapshot(limit: 100).items.first!
        try coworker.upsert(.fromText("one", source: "Coworker"))
        try coworker.upsert(.fromText("two", source: "Coworker"))
        XCTAssertEqual(try clippy.snapshot(limit: 100).items.count, 2)
        XCTAssertEqual(try clippy.snapshot(limit: 100).items.last?.id, first.id)
        try coworker.remove(id: first.id)
        try clippy.moveToFront(id: first.id)
        XCTAssertEqual(try clippy.snapshot(limit: 100).items.map(\.textContent), ["two"])
        try coworker.clear()
        try clippy.upsert(.fromText("after clear", source: "Clippy"))
        XCTAssertEqual(try coworker.snapshot(limit: 100).items.map(\.textContent), ["after clear"])
    }

    func testConcurrentConnectionsDoNotLoseCopies() throws {
        let first = try store(), second = try store()
        let failures = Failures()
        DispatchQueue.concurrentPerform(iterations: 80) { i in
            do { try (i % 2 == 0 ? first : second).upsert(.fromText("clip \(i)", source: "test")) }
            catch { failures.add(error) }
        }
        XCTAssertEqual(failures.count, 0)
        XCTAssertEqual(try first.snapshot(limit: 400).items.count, 80)
        XCTAssertEqual(try second.snapshot(limit: 10).items.count, 10)
        XCTAssertEqual(try first.snapshot(limit: 400).items.count, 80, "A smaller view must not truncate shared history")
    }

    func testThousandClipsSurviveSmallerViewsAndPruneOnlyOldest() throws {
        let clippy = try store(), coworker = try store()
        for i in 0...1_000 {
            try (i.isMultiple(of: 2) ? clippy : coworker).upsert(
                ClipboardItem(contentType: .text, timestamp: Date(timeIntervalSince1970: Double(i)),
                              textContent: "clip \(i)"))
        }
        XCTAssertEqual(try clippy.snapshot(limit: 500).items.count, 500)
        let retained = try coworker.snapshot(limit: 2_000).items
        XCTAssertEqual(retained.count, 1_000)
        XCTAssertEqual(retained.first?.textContent, "clip 1000")
        XCTAssertEqual(retained.last?.textContent, "clip 1")
        XCTAssertEqual(try clippy.snapshot(limit: 1_000).items.map(\.id), retained.map(\.id))
    }

    func testLegacyImportUsesSameThousandClipRetention() throws {
        let shared = try store()
        let legacy = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let items = (0...1_000).map {
            ClipboardItem(contentType: .text, timestamp: Date(timeIntervalSince1970: Double($0)),
                          textContent: "legacy \($0)")
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(items).write(to: legacy.appendingPathComponent("history.json"))
        try shared.importLegacy(directory: legacy, identifier: "clippy")
        let retained = try shared.snapshot(limit: 2_000).items
        XCTAssertEqual(retained.count, 1_000)
        XCTAssertEqual(retained.first?.textContent, "legacy 1000")
        XCTAssertEqual(retained.last?.textContent, "legacy 1")
    }

    func testLegacyImportsAreAtomicAndNeverResurrectClearedHistory() throws {
        let shared = try store()
        let legacy = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let path = legacy.appendingPathComponent("history.json")
        try Data("broken json".utf8).write(to: path)
        XCTAssertThrowsError(try shared.importLegacy(directory: legacy, identifier: "clippy"))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([ClipboardItem.fromText("old clip", source: "test")]).write(to: path)
        try shared.importLegacy(directory: legacy, identifier: "clippy")
        XCTAssertEqual(try shared.snapshot(limit: 400).items.count, 1)
        try shared.clear()
        try shared.importLegacy(directory: legacy, identifier: "clippy")
        XCTAssertTrue(try shared.snapshot(limit: 400).items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), "Migration preserves the original file")
    }

    func testImagesRemainAvailableAcrossAppsAndAreCleared() throws {
        let first = try store(), second = try store()
        let bytes = Data([1, 2, 3, 4, 5])
        try first.upsert(ClipboardItem(contentType: .image, imageData: bytes))
        try second.upsert(ClipboardItem(contentType: .image, imageData: bytes))
        let snapshot = try second.snapshot(limit: 400)
        XCTAssertEqual(snapshot.items.count, 1)
        let image = root.appendingPathComponent("shared/images").appendingPathComponent(snapshot.items[0].imageFileName!)
        XCTAssertEqual(try Data(contentsOf: image), bytes)
        try first.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
    }

    func testFutureProtocolIsNotOverwritten() throws {
        _ = try store()
        var db: OpaquePointer?
        let path = root.appendingPathComponent("shared/shared-history.sqlite").path
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version=2", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertThrowsError(try store())
    }
}

private final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Error] = []
    func add(_ error: Error) { lock.lock(); defer { lock.unlock() }; values.append(error) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}
