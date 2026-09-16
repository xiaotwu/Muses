import Foundation
import SwiftData
import Testing
@testable import Muses

@MainActor
@Suite("Reviewed catalog identity migration", .serialized)
struct CatalogIdentityMigrationTests {
    @Test("Export a disposable fixture for explicit UI validation",
          .enabled(if: ProcessInfo.processInfo.environment["MUSES_EXPORT_MIGRATION_FIXTURE"] == "1"))
    func exportUIFixture() throws {
        let (container, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let targetDirectory = URL(fileURLWithPath: "/tmp/muses-identity-ui-validation")
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let snapshot = try StoreUpgradeSnapshot.identityMigrationSnapshot(at: CatalogIdentityMigration.storeURL(container))
        try StoreUpgradeSnapshot.restore(snapshot: snapshot, to: targetDirectory.appending(path: "migration-ui-fixture.sqlite"))
    }

    private func fixture() throws -> (ModelContainer, URL, UUID) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "muses-migration-\(UUID())")
        let store = directory.appending(path: "library.sqlite")
        let container = try makeModelContainer(storeURL: store)
        let context = ModelContext(container)
        let track = Track(title: "Song", artist: "Uploader", youTubeId: "abcdefghijk", playCount: 4, liked: true)
        context.insert(track)
        let album = YouTubeImport(playlistId: "OLAK5uy_album", url: "https://music.youtube.com/playlist?list=OLAK5uy_album", title: "Album", channel: "Uploader")
        context.insert(album)
        for order in [0, 2] {
            let item = YouTubeImportItem(youTubeId: track.youTubeId, title: track.title, artist: track.artist, order: order)
            item.import_ = album
            item.track = track
            context.insert(item)
            context.insert(PlaylistItem(order: order, track: track))
        }
        context.insert(TrackNote(trackId: track.id, content: "Keep my note"))
        context.insert(TrackBookmark(trackId: track.id, timestampMs: 12000, title: "Bookmark"))
        context.insert(ListeningEvent(trackId: track.id, trackTitle: track.title, artist: track.artist,
                                      startedAt: Date(), listenedMs: 42000, outcome: .completed))
        try context.save()
        return (container, directory, track.id)
    }

    @Test("Apply saves an independent snapshot and preserves all other persisted user data")
    func applyAndUndoPreserveData() throws {
        let (container, directory, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogIdentityMigration.storeURL(container)
        let original = try CatalogMigrationAudit.read(store)
        let preview = try CatalogIdentityPreview.read(from: container)
        let receipt = try CatalogIdentityMigration.apply(preview, to: container)
        #expect(receipt.state == .applied)
        #expect(try CatalogMigrationAudit.read(store) == original)
        #expect(try CatalogMigrationAudit.read(receipt.snapshot) == original)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Track>()).first?.releaseCatalogID == "playlist:OLAK5uy_album")
        #expect(try FileManager.default.attributesOfItem(atPath: receipt.fileURL.path)[.posixPermissions] as? Int == 0o600)

        // Changes after migration must survive an explicit rollback.
        let edits = ModelContext(container)
        let track = try #require(edits.fetch(FetchDescriptor<Track>()).first)
        track.liked = false
        track.playCount = 8
        edits.insert(TrackNote(trackId: id, content: "A later note"))
        try edits.save()
        let beforeUndo = try CatalogMigrationAudit.read(store)
        let loaded = try #require(try CatalogIdentityMigration.latestReceipt(in: container))
        let undone = try CatalogIdentityMigration.rollback(loaded, in: container)
        #expect(undone.state == .rolledBack)
        #expect(try CatalogMigrationAudit.read(store) == beforeUndo)
        let saved = try #require(ModelContext(container).fetch(FetchDescriptor<Track>()).first)
        #expect(saved.id == id && saved.releaseCatalogID == nil && !saved.liked && saved.playCount == 8)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TrackNote>()) == 2)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PlaylistItem>()) == 2)
    }

    @Test("Preview changes reject migration before creating a receipt")
    func stalePreview() throws {
        let (container, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preview = try CatalogIdentityPreview.read(from: container)
        let edits = ModelContext(container)
        try #require(edits.fetch(FetchDescriptor<YouTubeImportItem>()).first).order = 9
        try edits.save()
        #expect(throws: (any Error).self) { try CatalogIdentityMigration.apply(preview, to: container) }
        #expect(try CatalogIdentityMigration.latestReceipt(in: container) == nil)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Track>()).first?.releaseCatalogID == nil)
    }

    @Test("Post-save failure restores the original identity and leaves recovery evidence")
    func applyFailureRecovers() throws {
        enum Failure: Error { case injected }
        let (container, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogIdentityMigration.storeURL(container)
        let original = try CatalogMigrationAudit.read(store)
        let preview = try CatalogIdentityPreview.read(from: container)
        #expect(throws: Failure.self) {
            try CatalogIdentityMigration.apply(preview, to: container, afterSave: { throw Failure.injected })
        }
        #expect(try CatalogMigrationAudit.read(store) == original)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Track>()).first?.releaseCatalogID == nil)
        #expect(try CatalogIdentityMigration.latestReceipt(in: container)?.state == .rolledBack)
    }

    @Test("Rollback failure retains applied identity; conflicting newer identity is never overwritten")
    func rollbackFailureAndConflict() throws {
        enum Failure: Error { case injected }
        let (container, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let receipt = try CatalogIdentityMigration.apply(CatalogIdentityPreview.read(from: container), to: container)
        #expect(throws: Failure.self) {
            try CatalogIdentityMigration.rollback(receipt, in: container, afterSave: { throw Failure.injected })
        }
        #expect(try ModelContext(container).fetch(FetchDescriptor<Track>()).first?.releaseCatalogID == receipt.changes.first?.after)
        let edits = ModelContext(container)
        try #require(edits.fetch(FetchDescriptor<Track>()).first).releaseCatalogID = "browse:newer"
        try edits.save()
        #expect(throws: (any Error).self) { try CatalogIdentityMigration.rollback(receipt, in: container) }
        #expect(try ModelContext(container).fetch(FetchDescriptor<Track>()).first?.releaseCatalogID == "browse:newer")
    }

    @Test("Receipt survives reopening and does not replay writes automatically")
    func receiptSurvivesRestart() throws {
        let (container, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let receipt = try CatalogIdentityMigration.apply(CatalogIdentityPreview.read(from: container), to: container)
        let reopened = try makeModelContainer(storeURL: directory.appending(path: "library.sqlite"))
        let loaded = try #require(try CatalogIdentityMigration.latestReceipt(in: reopened))
        #expect(loaded == receipt)
        #expect(try CatalogIdentityMigration.rollback(loaded, in: reopened).state == .rolledBack)
    }

    @Test("Interrupted rollback is reconciled explicitly, without replaying startup writes")
    func interruptedRollback() throws {
        let (container, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var receipt = try CatalogIdentityMigration.apply(CatalogIdentityPreview.read(from: container), to: container)
        receipt.state = .rollingBack
        try JSONEncoder().encode(receipt).write(to: receipt.fileURL, options: .atomic)
        let edit = ModelContext(container)
        try #require(edit.fetch(FetchDescriptor<Track>()).first).releaseCatalogID = nil
        try edit.save()
        let loaded = try #require(try CatalogIdentityMigration.latestReceipt(in: container))
        #expect(loaded.state == .rollingBack)
        #expect(throws: (any Error).self) {
            try CatalogIdentityMigration.apply(CatalogIdentityPreview.read(from: container), to: container)
        }
        #expect(try CatalogIdentityMigration.rollback(loaded, in: container).state == .rolledBack)
    }

    @Test("Independent snapshot restores a complete pre-migration library")
    func fullSnapshotRecovery() throws {
        let (container, directory, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let receipt = try CatalogIdentityMigration.apply(CatalogIdentityPreview.read(from: container), to: container)
        let recoveredURL = directory.appending(path: "recovered.sqlite")
        try StoreUpgradeSnapshot.restore(snapshot: receipt.snapshot, to: recoveredURL)
        let recovered = try makeModelContainer(storeURL: recoveredURL)
        let track = try #require(ModelContext(recovered).fetch(FetchDescriptor<Track>()).first)
        #expect(track.id == id && track.releaseCatalogID == nil && track.liked && track.playCount == 4)
        #expect(try CatalogMigrationAudit.read(recoveredURL) == receipt.audit)
    }
}
