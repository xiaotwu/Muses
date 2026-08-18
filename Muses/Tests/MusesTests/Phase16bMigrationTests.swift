import Testing
import Foundation
import SwiftData
@testable import Muses

/// Phase 16b — SwiftData migration infrastructure.
///
/// Covers three guarantees required by the Final Spec audit:
/// 1. The V0 → V1 lightweight stage actually migrates a V0 fixture (additive tables,
///    preserved rows) and stamps the new version.
/// 2. An existing *unversioned* store (what every shipping build produced) opens
///    cleanly under the new versioned schema + plan with no data loss — the
///    critical backwards-compatibility proof for real user databases.
/// 3. The corrupt-store backup fallback copies the DB without deleting it.
@Suite("Phase16b Migration")
struct Phase16bMigrationTests {

    private func tempStoreURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "MusesMigrationTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "muses.sqlite")
    }

    private func cleanup(_ url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - 1. V0 fixture → V1 lightweight migration

    @Test("V0 fixture migrates to V1: rows preserved, new tables present")
    func v0FixtureMigratesToV1() throws {
        let url = tempStoreURL()
        defer { cleanup(url) }

        let trackId = UUID()
        let albumId = UUID()

        // Build a V0 store with the 10 baseline models and seed Track + Album.
        do {
            let v0Schema = Schema(versionedSchema: MusesSchemaV0.self)
            let container = try ModelContainer(for: v0Schema, configurations: ModelConfiguration(url: url))
            let ctx = ModelContext(container)
            let album = Album(id: albumId, title: "Migration", albumArtist: "Tester")
            ctx.insert(album)
            let track = Track(id: trackId, source: .local, title: "Seed", artist: "Tester")
            track.albumTitle = "Migration"
            ctx.insert(track)
            try ctx.save()
        }

        // Reopen under the versioned V1 schema + plan: triggers V0 → V1 lightweight.
        let v1Schema = Schema(versionedSchema: MusesSchemaV1.self)
        let container = try ModelContainer(for: v1Schema,
                                           migrationPlan: MusesMigrationPlan.self,
                                           configurations: ModelConfiguration(url: url))
        let ctx = ModelContext(container)

        let trackDesc = FetchDescriptor<Track>()
        let tracks = try ctx.fetch(trackDesc)
        #expect(tracks.count == 1)
        #expect(tracks.first?.id == trackId)
        #expect(tracks.first?.title == "Seed")

        let albumDesc = FetchDescriptor<Album>()
        let albums = try ctx.fetch(albumDesc)
        #expect(albums.count == 1)
        #expect(albums.first?.id == albumId)

        // A Phase-17 model table now exists and is queryable (empty here).
        let eventDesc = FetchDescriptor<ListeningEvent>()
        let events = try ctx.fetch(eventDesc)
        #expect(events.isEmpty)

        // A Phase-25 model table too.
        let focusDesc = FetchDescriptor<FocusSession>()
        let focus = try ctx.fetch(focusDesc)
        #expect(focus.isEmpty)
    }

    // MARK: - 2. Existing unversioned store opens cleanly under versioned schema

    @Test("Unversioned current store opens under versioned schema with no data loss")
    func unversionedStoreOpensUnderVersionedSchema() throws {
        let url = tempStoreURL()
        defer { cleanup(url) }

        let trackId = UUID()

        // Reproduce exactly what every shipping build did: an *unversioned*
        // `Schema([...])` (default version 1.0.0) holding all 18 current models.
        do {
            let unversioned = Schema([
                Track.self, Album.self, Artist.self, ScanRoot.self, QueueState.self, EQPreset.self,
                YouTubeImport.self, YouTubeImportItem.self, Playlist.self, PlaylistItem.self,
                ListeningEvent.self, ListeningSession.self, InboxItem.self,
                TrackNote.self, TrackBookmark.self, AlbumNote.self,
                AutomationRule.self, FocusSession.self,
            ])
            let container = try ModelContainer(for: unversioned, configurations: ModelConfiguration(url: url))
            let ctx = ModelContext(container)
            let track = Track(id: trackId, source: .local, title: "Existing", artist: "User")
            ctx.insert(track)
            try ctx.save()
        }

        // Now open with the new versioned V1 schema + migration plan — this is
        // what real user databases experience on upgrade. Must not throw or lose rows.
        let container = try ModelContainer(for: MusesSchema.v1,
                                          migrationPlan: MusesMigrationPlan.self,
                                          configurations: ModelConfiguration(url: url))
        let ctx = ModelContext(container)
        let tracks = try ctx.fetch(FetchDescriptor<Track>())
        #expect(tracks.count == 1)
        #expect(tracks.first?.id == trackId)
        #expect(tracks.first?.title == "Existing")
    }

    // MARK: - 3. Corrupt-store backup never deletes the original

    @Test("backupCorruptStore copies files without deleting the original")
    func backupPreservesOriginal() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "MusesBackupTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = dir.appending(path: "muses.sqlite")
        try Data("sqlite".utf8).write(to: store)
        try Data("wal".utf8).write(to: dir.appending(path: "muses.sqlite-wal"))

        backupCorruptStore(at: store)

        // Original files must still exist.
        #expect(FileManager.default.fileExists(atPath: store.path))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "muses.sqlite-wal").path))

        // A corrupt-<stamp> copy must exist.
        let copies = (try FileManager.default.contentsOfDirectory(atPath: dir.path))
            .filter { $0.hasPrefix("muses-corrupt-") && $0.hasSuffix(".sqlite") }
        #expect(copies.count == 1)
    }
}