import Foundation
import SQLite3

/// One-time, WAL-consistent recovery copy before the membership/queue schema upgrade.
/// The source is query-only and never renamed or deleted. Closed WAL stores may
/// need SQLite to create coordination sidecars before their schema can be read.
enum StoreUpgradeSnapshot {
    enum SnapshotError: Error { case database, invalidSnapshot, destinationExists }

    static func prepareIfNeeded(at source: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let database = try openForReading(source)
        defer { sqlite3_close(database) }
        // An upgraded store needs no additional recovery copy on normal launches.
        if try hasColumn("ZLIBRARYMEMBER", table: "ZTRACK", database: database),
           try hasColumn("ZINSERTEDCURRENTJSON", table: "ZQUEUESTATE", database: database),
           try hasColumn("ZSMARTSHUFFLEJSON", table: "ZQUEUESTATE", database: database) {
            return nil
        }
        return try archive(database: database, source: source, prefix: "membership-upgrade-recovery")
    }

    /// Independent recovery copy for the explicitly reviewed identity migration.
    static func identityMigrationSnapshot(at source: URL) throws -> URL {
        let database = try openForReading(source)
        defer { sqlite3_close(database) }
        try validate(database)
        return try archive(database: database, source: source, prefix: "catalog-identity-recovery")
    }

    private static func archive(database: OpaquePointer, source: URL, prefix: String) throws -> URL {
        let directory = source.deletingLastPathComponent()
            .appending(path: "\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let snapshot = directory.appending(path: "before-upgrade.sqlite")
        do {
            try copy(database: database, to: snapshot)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
            // Persist only completion metadata, never user content or credentials.
            let manifest = Manifest(version: 1, createdAt: Date(), byteCount: try snapshot.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            try JSONEncoder().encode(manifest).write(to: directory.appending(path: "manifest.json"), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appending(path: "manifest.json").path)
            return snapshot
        } catch {
            // An incomplete copy must not look like a recoverable snapshot.
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Restores into an independent destination for validation before activation.
    /// Never overwrites an open or existing user store (including its WAL family).
    static func restore(snapshot: URL, to destination: URL) throws {
        guard ["", "-wal", "-shm"].allSatisfy({
            !FileManager.default.fileExists(atPath: destination.path + $0)
        }) else { throw SnapshotError.destinationExists }
        let database = try openForReading(snapshot)
        defer { sqlite3_close(database) }
        try validate(database)
        try copy(database: database, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private struct Manifest: Codable {
        let version: Int
        let createdAt: Date
        let byteCount: Int
    }

    private static func open(_ url: URL, flags: Int32) throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw SnapshotError.database
        }
        sqlite3_busy_timeout(database, 1000)
        return database
    }

    static func openForReading(_ url: URL) throws -> OpaquePointer {
        var database = try open(url, flags: SQLITE_OPEN_READONLY)
        let status = sqlite3_exec(database, "PRAGMA schema_version", nil, nil, nil)
        if status == SQLITE_OK { return database }
        sqlite3_close(database)
        guard status == SQLITE_CANTOPEN else { throw SnapshotError.database }
        // Apple SQLite cannot initialize missing WAL/SHM files through a
        // read-only handle. Do not use immutable=1: it can miss a live WAL.
        // Query-only still prohibits row/schema writes and honors WAL locks.
        database = try open(url, flags: SQLITE_OPEN_READWRITE)
        guard sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(database, "PRAGMA schema_version", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw SnapshotError.database
        }
        return database
    }

    private static func hasColumn(_ column: String, table: String, database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            throw SnapshotError.database
        }
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == column { return true }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw SnapshotError.database }
        return false
    }

    private static func copy(database: OpaquePointer, to destination: URL) throws {
        let target = try open(destination, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_EXCLUSIVE)
        defer { sqlite3_close(target) }
        guard let backup = sqlite3_backup_init(target, "main", database, "main") else {
            throw SnapshotError.database
        }
        let result = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finished == SQLITE_OK else { throw SnapshotError.database }
        try validate(target)
    }

    private static func validate(_ database: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK else {
            throw SnapshotError.invalidSnapshot
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0), String(cString: value) == "ok",
              sqlite3_step(statement) == SQLITE_DONE else { throw SnapshotError.invalidSnapshot }
    }
}
