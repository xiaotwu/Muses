import Foundation
import SQLite3
import Testing
@testable import Muses

@Suite("Store upgrade recovery")
struct StoreUpgradeSnapshotTests {
    @Test("Closed WAL files without sidecars remain readable and reject writes")
    func closedWALSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.sqlite")
        var writer: OpaquePointer?
        #expect(sqlite3_open(source.path, &writer) == SQLITE_OK)
        #expect(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; CREATE TABLE ZTRACK (ZID TEXT); INSERT INTO ZTRACK VALUES ('original');", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_close(writer) == SQLITE_OK)
        let copy = directory.appending(path: "closed-copy.sqlite")
        try FileManager.default.copyItem(at: source, to: copy)
        #expect(!FileManager.default.fileExists(atPath: copy.path + "-wal"))
        let reader = try StoreUpgradeSnapshot.openForReading(copy)
        #expect(sqlite3_exec(reader, "INSERT INTO ZTRACK VALUES ('must-not-write')", nil, nil, nil) == SQLITE_READONLY)
        sqlite3_close(reader)
        let recovery = try StoreUpgradeSnapshot.prepareIfNeeded(at: copy)
        let snapshot = try #require(recovery)
        let recovered = try StoreUpgradeSnapshot.openForReading(snapshot)
        defer { sqlite3_close(recovered) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(recovered, "SELECT ZID FROM ZTRACK", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(String(cString: sqlite3_column_text(statement, 0)) == "original")
        #expect(sqlite3_step(statement) == SQLITE_DONE)
    }

    @Test("Snapshot includes committed WAL rows and restores to a separate store")
    func walSnapshotAndRestore() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.sqlite")
        var database: OpaquePointer?
        #expect(sqlite3_open(source.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE ZTRACK (ZID TEXT, ZLIKED INTEGER); INSERT INTO ZTRACK VALUES ('original-id', 1);", nil, nil, nil) == SQLITE_OK)
        let snapshot = try #require(try StoreUpgradeSnapshot.prepareIfNeeded(at: source))
        #expect(FileManager.default.fileExists(atPath: source.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: snapshot.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(sqlite3_exec(database, "UPDATE ZTRACK SET ZLIKED = 0;", nil, nil, nil) == SQLITE_OK)
        let restored = directory.appending(path: "restored.sqlite")
        try StoreUpgradeSnapshot.restore(snapshot: snapshot, to: restored)
        var recovered: OpaquePointer?
        #expect(sqlite3_open_v2(restored.path, &recovered, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(recovered) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(recovered, "SELECT ZID, ZLIKED FROM ZTRACK", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(String(cString: sqlite3_column_text(statement, 0)) == "original-id")
        #expect(sqlite3_column_int(statement, 1) == 1)
        #expect(sqlite3_step(statement) == SQLITE_DONE)
        #expect(throws: StoreUpgradeSnapshot.SnapshotError.destinationExists) {
            try StoreUpgradeSnapshot.restore(snapshot: snapshot, to: source)
        }
    }

    @Test("Isolated pre-upgrade store opens without changing membership or row counts",
          .enabled(if: ProcessInfo.processInfo.environment["MUSES_UPGRADE_TEST_COPY"] != nil))
    @MainActor func isolatedUpgrade() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MUSES_UPGRADE_TEST_COPY"])
        let store = URL(fileURLWithPath: path)
        // This hook only accepts an explicitly supplied disposable copy.
        #expect(store.lastPathComponent == "isolated-upgrade-test.sqlite")
        guard store.lastPathComponent == "isolated-upgrade-test.sqlite" else { return }
        let container = try makeModelContainer(storeURL: store)
        let library = LibraryService(modelContainer: container)
        #expect(library.allTracks().allSatisfy { $0.isInLibrary })
        #expect(try StoreUpgradeSnapshot.prepareIfNeeded(at: store) == nil)
    }

    @Test("Current schema and new stores do not create recovery copies")
    func currentSchemaSkipsSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appending(path: "current.sqlite")
        #expect(try StoreUpgradeSnapshot.prepareIfNeeded(at: store) == nil)
        let container = try makeModelContainer(storeURL: store)
        #expect(try StoreUpgradeSnapshot.prepareIfNeeded(at: store) == nil)
        withExtendedLifetime(container) {}
    }
}
