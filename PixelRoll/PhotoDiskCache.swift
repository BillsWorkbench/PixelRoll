import Foundation
import CryptoKit
import SQLite3

nonisolated struct PhotoFingerprint: Codable, Equatable, Sendable {
    let modified: Double
    let size: Int

    static func read(_ url: URL) -> PhotoFingerprint? {
        // A fresh URL avoids reusing resource values cached by a previous directory scan.
        let fresh = URL(fileURLWithPath: url.path)
        guard let values = try? fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let date = values.contentModificationDate, let size = values.fileSize else { return nil }
        return PhotoFingerprint(modified: date.timeIntervalSince1970, size: size)
    }
    var token: String { "\(modified.bitPattern):\(size)" }
}

// SQLite serializes short cache operations; RAW decoding happens outside this lock.
// Every record is disposable. Failure to open/read/write the cache falls back to the source photo.
nonisolated final class PhotoDiskCache: @unchecked Sendable {
    static let shared = PhotoDiskCache(directory: ProcessInfo.processInfo.environment["PIXELROLL_CACHE_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) })
    enum Kind: Int32 { case thumbnail = 1, metadata = 2, adjustedThumbnail = 3 }
    private let lock = NSLock()
    private var database: OpaquePointer?
    private let limit: Int
    private var storedBytes = 0
    private var writes = 0
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let directory: URL

    init(directory: URL? = nil, maximumBytes: Int = 1_024 * 1_024 * 1_024) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("photo.pixelroll.app/PhotoCache-v1", isDirectory: true)
        limit = max(0, maximumBytes)
        do { try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true) }
        catch { return }
        let url = self.directory.appendingPathComponent("photos.sqlite")
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return }
        for attempt in 0..<2 {
            guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                if let database { sqlite3_close(database) }; database = nil; return
            }
            sqlite3_busy_timeout(database, 250)
            run("PRAGMA auto_vacuum=INCREMENTAL")
            run("PRAGMA journal_mode=WAL")
            run("PRAGMA synchronous=NORMAL")
            run("PRAGMA wal_autocheckpoint=256")
            run("PRAGMA journal_size_limit=8388608")
            run("PRAGMA cache_size=-8192")
            if run("CREATE TABLE IF NOT EXISTS entries (key TEXT NOT NULL, kind INTEGER NOT NULL, fingerprint TEXT NOT NULL, payload BLOB NOT NULL, accessed REAL NOT NULL, PRIMARY KEY(key,kind))") {
                run("CREATE INDEX IF NOT EXISTS entry_age ON entries(accessed)")
                break
            }
            let error = sqlite3_errcode(database)
            sqlite3_close(database); database = nil
            guard attempt == 0, error == SQLITE_NOTADB || error == SQLITE_CORRUPT else { return }
            // This database contains only regenerable cache data.
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        guard database != nil else { return }
        storedBytes = byteCount()
        prune()
    }

    deinit { if let database { sqlite3_close(database) } }

    static func key(for url: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func read(_ kind: Kind, key: String, fingerprint: PhotoFingerprint) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let database else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT payload FROM entries WHERE key=? AND kind=? AND fingerprint=?", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, at: 1)
        sqlite3_bind_int(statement, 2, kind.rawValue)
        bind(fingerprint.token, to: statement, at: 3)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0, count <= 16 * 1_024 * 1_024 else { return nil }
        let result = Data(bytes: bytes, count: count)
        var touch: OpaquePointer?
        if sqlite3_prepare_v2(database, "UPDATE entries SET accessed=? WHERE key=? AND kind=?", -1, &touch, nil) == SQLITE_OK {
            sqlite3_bind_double(touch, 1, Date().timeIntervalSince1970)
            bind(key, to: touch, at: 2); sqlite3_bind_int(touch, 3, kind.rawValue)
            sqlite3_step(touch)
        }
        sqlite3_finalize(touch)
        return result
    }

    func write(_ data: Data, kind: Kind, key: String, fingerprint: PhotoFingerprint) {
        guard !data.isEmpty, data.count <= min(limit, 16 * 1_024 * 1_024) else { return }
        lock.lock(); defer { lock.unlock() }
        guard let database else { return }
        var sizeQuery: OpaquePointer?
        var previousBytes = 0
        if sqlite3_prepare_v2(database, "SELECT length(payload) FROM entries WHERE key=? AND kind=?", -1, &sizeQuery, nil) == SQLITE_OK {
            bind(key, to: sizeQuery, at: 1); sqlite3_bind_int(sizeQuery, 2, kind.rawValue)
            if sqlite3_step(sizeQuery) == SQLITE_ROW { previousBytes = Int(sqlite3_column_int64(sizeQuery, 0)) }
        }
        sqlite3_finalize(sizeQuery)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO entries(key,kind,fingerprint,payload,accessed) VALUES(?,?,?,?,?)", -1, &statement, nil) == SQLITE_OK else { return }
        bind(key, to: statement, at: 1); sqlite3_bind_int(statement, 2, kind.rawValue)
        bind(fingerprint.token, to: statement, at: 3)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32($0.count), transient) }
        sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
        let saved = sqlite3_step(statement) == SQLITE_DONE
        sqlite3_finalize(statement)
        if saved {
            // Include both thumbnail and metadata payloads in the same disk budget.
            storedBytes = max(0, storedBytes - previousBytes + data.count)
            writes += 1
            if writes % 64 == 0 { storedBytes = byteCount() }
            prune()
        }
    }

    struct Usage: Sendable {
        let available: Bool
        let bytes: Int
        let limit: Int
        let thumbnails: Int
        let metadata: Int
    }

    func usage() -> Usage {
        lock.lock(); defer { lock.unlock() }
        guard let database else { return Usage(available: false, bytes: 0, limit: limit, thumbnails: 0, metadata: 0) }
        var statement: OpaquePointer?
        var thumbnails = 0
        var metadata = 0
        if sqlite3_prepare_v2(database, "SELECT kind, COUNT(*) FROM entries GROUP BY kind", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if [Kind.thumbnail.rawValue, Kind.adjustedThumbnail.rawValue].contains(sqlite3_column_int(statement, 0)) { thumbnails += Int(sqlite3_column_int64(statement, 1)) }
                if sqlite3_column_int(statement, 0) == Kind.metadata.rawValue { metadata = Int(sqlite3_column_int64(statement, 1)) }
            }
        }
        sqlite3_finalize(statement)
        let bytes = ["photos.sqlite", "photos.sqlite-wal", "photos.sqlite-shm"].reduce(0) { result, name in
            result + ((try? directory.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return Usage(available: true, bytes: bytes, limit: limit, thumbnails: thumbnails, metadata: metadata)
    }

    @discardableResult func clear() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard database != nil, run("DELETE FROM entries") else { return false }
        storedBytes = 0
        run("PRAGMA wal_checkpoint(TRUNCATE)")
        run("VACUUM")
        return true
    }

    @discardableResult func removeMetadata(for urls: [URL]) -> Bool {
        let keys = urls.map(Self.key)
        lock.lock(); defer { lock.unlock() }
        guard let database, run("BEGIN IMMEDIATE") else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM entries WHERE key=? AND kind=2", -1, &statement, nil) == SQLITE_OK else {
            run("ROLLBACK"); return false
        }
        var success = true
        for key in keys {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            bind(key, to: statement, at: 1)
            if sqlite3_step(statement) != SQLITE_DONE { success = false; break }
        }
        sqlite3_finalize(statement)
        if success { success = run("COMMIT") }
        if !success { run("ROLLBACK") }
        storedBytes = byteCount()
        return success
    }

    private func bind(_ text: String, to statement: OpaquePointer?, at index: Int32) {
        _ = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
    }
    @discardableResult private func run(_ sql: String) -> Bool {
        sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
    }
    private func byteCount() -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COALESCE(SUM(length(payload)),0) FROM entries", -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }
    private func prune() {
        var pruned = false
        while storedBytes > limit {
            guard run("DELETE FROM entries WHERE rowid=(SELECT rowid FROM entries ORDER BY accessed LIMIT 1)"), sqlite3_changes(database) > 0 else { break }
            storedBytes = byteCount()
            pruned = true
        }
        if pruned { run("PRAGMA incremental_vacuum(64)") }
    }
}
