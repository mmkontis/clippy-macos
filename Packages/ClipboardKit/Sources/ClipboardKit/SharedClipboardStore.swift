import Foundation
import CryptoKit
import SQLite3

/// Local protocol v1: mutation-based SQLite transactions, immutable image files,
/// one-time legacy imports, and a revision counter for cross-app refreshes.
final class SharedClipboardStore: @unchecked Sendable {
    struct Snapshot { let revision: Int64; let items: [ClipboardItem] }
    enum StoreError: Error { case database(String), invalidImage, newerProtocol }
    private enum Value { case text(String), data(Data), number(Double) }
    private var database: OpaquePointer?
    private let lock = NSLock()
    let directory: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("images"), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("shared-history.sqlite").path
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            database = nil
            throw StoreError.database("Could not open shared history")
        }
        do {
            sqlite3_busy_timeout(database, 5000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA secure_delete=ON")
            let version = try integer("PRAGMA user_version")
            guard version <= 1 else { throw StoreError.newerProtocol }
            try execute("CREATE TABLE IF NOT EXISTS clips (fingerprint TEXT PRIMARY KEY, id TEXT NOT NULL UNIQUE, modified REAL NOT NULL, payload BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value INTEGER NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS clients (id TEXT PRIMARY KEY)")
            try execute("INSERT OR IGNORE INTO metadata VALUES ('revision', 0)")
            try execute("PRAGMA user_version=1")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    func register(client: String) throws {
        try transaction { try execute("INSERT OR IGNORE INTO clients VALUES (?)", [.text(client)]) }
    }

    func hasClient(_ client: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try integer("SELECT COUNT(*) FROM clients WHERE id=?", [.text(client)]) > 0
    }

    func snapshot(limit: Int) throws -> Snapshot {
        try transaction(readOnly: true) {
            let revision = try integer("SELECT value FROM metadata WHERE key='revision'")
            let statement = try prepare("SELECT payload FROM clips ORDER BY modified DESC, id LIMIT ?", [.number(Double(max(1, limit)))])
            defer { sqlite3_finalize(statement) }
            var items: [ClipboardItem] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                items.append(try decode(blob(statement, column: 0)))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw error() }
            return Snapshot(revision: revision, items: items)
        }
    }

    func upsert(_ item: ClipboardItem, imageDirectory: URL? = nil) throws {
        try transaction {
            try insert(item, imageDirectory: imageDirectory, onlyIfNewer: false)
            try execute("DELETE FROM clips WHERE id NOT IN (SELECT id FROM clips ORDER BY modified DESC, id LIMIT 400)")
            try bumpRevision()
        }
        try collectUnusedImages()
    }

    func remove(id: UUID) throws {
        try transaction {
            try execute("DELETE FROM clips WHERE id=?", [.text(id.uuidString)])
            try bumpRevision()
        }
        try collectUnusedImages()
    }

    func moveToFront(id: UUID) throws {
        try transaction {
            // Never reinsert stale in-memory items after another app deleted them.
            try execute("UPDATE clips SET modified=? WHERE id=?", [.number(Date().timeIntervalSince1970), .text(id.uuidString)])
            if sqlite3_changes(database) > 0 { try bumpRevision() }
        }
    }

    func clear() throws {
        try transaction {
            try execute("DELETE FROM clips")
            try bumpRevision()
        }
        try collectUnusedImages()
        lock.lock(); defer { lock.unlock() }
        // Best effort: readers can temporarily prevent checkpointing.
        sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }

    /// Detects legacy history when it first appears. The import marker and data
    /// commit together, so reopening old files cannot resurrect deleted clips.
    func importLegacy(directory legacy: URL, identifier: String) throws {
        let history = legacy.appendingPathComponent("history.json")
        guard FileManager.default.fileExists(atPath: history.path) else { return }
        try transaction {
            let marker = "imported:" + identifier
            guard try integer("SELECT COUNT(*) FROM metadata WHERE key=?", [.text(marker)]) == 0 else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let oldItems = try decoder.decode([ClipboardItem].self, from: Data(contentsOf: history))
            for item in oldItems {
                // A missing legacy image should not discard otherwise valid history.
                do { try insert(item, imageDirectory: legacy.appendingPathComponent("images"), onlyIfNewer: true) }
                catch StoreError.invalidImage { continue }
            }
            try execute("INSERT INTO metadata VALUES (?, 1)", [.text(marker)])
            try execute("DELETE FROM clips WHERE id NOT IN (SELECT id FROM clips ORDER BY modified DESC, id LIMIT 400)")
            try bumpRevision()
        }
        try collectUnusedImages()
    }

    private func insert(_ source: ClipboardItem, imageDirectory: URL?, onlyIfNewer: Bool) throws {
        var item = source
        var fingerprintData = Data(source.contentType.rawValue.utf8)
        if source.contentType == .image {
            let image: Data?
            if let data = source.imageData { image = data }
            else if let name = source.imageFileName, name == URL(fileURLWithPath: name).lastPathComponent {
                image = try? Data(contentsOf: (imageDirectory ?? directory.appendingPathComponent("images")).appendingPathComponent(name))
            } else { image = nil }
            guard let image else { throw StoreError.invalidImage }
            fingerprintData.append(image)
            let filename = digest(image) + ".png"
            let imageURL = directory.appendingPathComponent("images").appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: imageURL.path) {
                try image.write(to: imageURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: imageURL.path)
            }
            item.imageFileName = filename
            item.imageData = nil
        } else {
            fingerprintData.append(Data((source.fileURLString ?? source.textContent ?? "").utf8))
        }
        let fingerprint = digest(fingerprintData)
        let lookup = try prepare("SELECT payload, modified FROM clips WHERE fingerprint=?", [.text(fingerprint)])
        defer { sqlite3_finalize(lookup) }
        if sqlite3_step(lookup) == SQLITE_ROW {
            if onlyIfNewer && sqlite3_column_double(lookup, 1) >= source.timestamp.timeIntervalSince1970 { return }
            let old = try decode(blob(lookup, column: 0))
            item = ClipboardItem(id: old.id, contentType: item.contentType, timestamp: item.timestamp,
                textContent: item.textContent, imageFileName: item.imageFileName,
                fileURLString: item.fileURLString, sourceApplication: item.sourceApplication)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try execute("INSERT INTO clips VALUES (?, ?, ?, ?) ON CONFLICT(fingerprint) DO UPDATE SET id=excluded.id, modified=excluded.modified, payload=excluded.payload",
            [.text(fingerprint), .text(item.id.uuidString), .number(item.timestamp.timeIntervalSince1970), .data(try encoder.encode(item))])
    }

    private func collectUnusedImages() throws {
        // Mutations are already committed. Hold the writer lock while collecting
        // immutable images, so an insertion cannot race with file cleanup.
        try transaction { try pruneImages() }
    }

    private func pruneImages() throws {
        let statement = try prepare("SELECT payload FROM clips")
        defer { sqlite3_finalize(statement) }
        var referenced = Set<String>()
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let name = try decode(blob(statement, column: 0)).imageFileName { referenced.insert(name) }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw error() }
        for file in try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("images"), includingPropertiesForKeys: nil) {
            if !referenced.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func decode(_ data: Data) throws -> ClipboardItem {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ClipboardItem.self, from: data)
    }
    private func blob(_ statement: OpaquePointer, column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
    private func error() -> StoreError { .database(String(cString: sqlite3_errmsg(database))) }
    private func bumpRevision() throws { try execute("UPDATE metadata SET value=value+1 WHERE key='revision'") }
    private func transaction<T>(readOnly: Bool = false, _ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute(readOnly ? "BEGIN DEFERRED" : "BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func prepare(_ sql: String, _ values: [Value] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .text(let text): status = sqlite3_bind_text(statement, index, text, -1, transient)
            case .number(let number): status = sqlite3_bind_double(statement, index, number)
            case .data(let data): status = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
            }
            if status != SQLITE_OK { sqlite3_finalize(statement); throw error() }
        }
        return statement
    }
    private func execute(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw error() }
    }
    private func integer(_ sql: String, _ values: [Value] = []) throws -> Int64 {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return 0 }
        guard status == SQLITE_ROW else { throw error() }
        return sqlite3_column_int64(statement, 0)
    }
}
