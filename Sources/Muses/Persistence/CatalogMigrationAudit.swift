import CryptoKit
import Foundation
import SQLite3

/// Logical user-data audit across the whole current store, including reference tables.
/// Only the migration's target column and Core Data's row version are excluded.
struct CatalogMigrationAudit: Codable, Equatable {
    struct Table: Codable, Equatable {
        let count: Int
        let digest: String
    }
    let tables: [String: Table]

    static func read(_ url: URL) throws -> Self {
        let database = try StoreUpgradeSnapshot.openForReading(url)
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2000)
        guard sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw CatalogMigrationError.auditFailed }
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }

        func rows(_ sql: String, consume: ([String]) throws -> Void) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw CatalogMigrationError.auditFailed
            }
            defer { sqlite3_finalize(statement) }
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                let values = (0..<sqlite3_column_count(statement)).map { index -> String in
                    guard let bytes = sqlite3_column_text(statement, index) else { return "NULL" }
                    return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
                }
                try consume(values)
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw CatalogMigrationError.auditFailed }
        }
        func identifier(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var names: [String] = []
        try rows("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Z%' ORDER BY name") { names.append($0[0]) }
        let internalTables: Set<String> = ["Z_METADATA", "Z_PRIMARYKEY", "Z_MODELCACHE"]
        var result: [String: Table] = [:]
        for name in names where !internalTables.contains(name) {
            var columns: [String] = []
            try rows("PRAGMA table_info(\(identifier(name)))") { columns.append($0[1]) }
            let included = columns.filter { !(name == "ZTRACK" && ["ZRELEASECATALOGID", "Z_OPT"].contains($0)) }
            guard !included.isEmpty else { throw CatalogMigrationError.auditFailed }
            let projection = included.map { "quote(\(identifier($0)))" }.joined(separator: ",")
            let ordering = columns.contains("Z_PK") ? identifier("Z_PK") : "rowid"
            var digest = SHA256()
            digest.update(data: try JSONEncoder().encode(included))
            var count = 0
            try rows("SELECT \(projection) FROM \(identifier(name)) ORDER BY \(ordering)") { row in
                digest.update(data: try JSONEncoder().encode(row))
                digest.update(data: Data([0x0A]))
                count += 1
            }
            result[name] = Table(count: count, digest: digest.finalize().map { String(format: "%02x", $0) }.joined())
        }
        guard result["ZTRACK"] != nil else { throw CatalogMigrationError.auditFailed }
        return Self(tables: result)
    }
}
