import Foundation
import SwiftData
import Testing
@testable import Muses

@MainActor
@Suite("Playlist membership and recovery UX")
struct PlaylistMembershipUXTests {
    @Test("Songs includes unplayed imports and deduplicates active playlist membership")
    func unionIncludesLazyItems() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let track = Track(title: "Alpha", artist: "Artist", youTubeId: "shared")
        let orphan = Track(title: "Orphan", artist: "Artist", youTubeId: "orphan")
        let local = Playlist(name: "Local")
        context.insert(track)
        context.insert(orphan)
        context.insert(local)
        let membership = PlaylistItem(order: 0, playlist: local, track: track)
        context.insert(membership)
        local.items = [membership]
        let imported = YouTubeImport(playlistId: "PL-test", url: "https://youtube.com/playlist?list=PL-test",
                                     title: "Imported", channel: "Artist")
        context.insert(imported)
        let duplicate = YouTubeImportItem(youTubeId: "shared", title: "Alpha", artist: "Artist")
        let lazy = YouTubeImportItem(youTubeId: "lazy", title: "Zulu", artist: "Artist")
        for item in [duplicate, lazy] { context.insert(item); item.import_ = imported }
        imported.items = [duplicate, lazy]
        try context.save()
        let union = CollectionTrackRow.playlistUnion(playlists: [local], imports: [imported])
        #expect(union.map(\.snapshot.youTubeId) == ["shared", "lazy"])
        #expect(union.map(\.canonicalIndex) == [0, 1])
        imported.deletedAt = .now
        #expect(CollectionTrackRow.playlistUnion(playlists: [local], imports: [imported])
            .map(\.snapshot.youTubeId) == ["shared"])
        #expect(CollectionTrackRow.playlistUnion(playlists: [], imports: [imported]).isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<Track>()) == 2)
        let library = LibraryService(modelContainer: container)
        let lazySnapshot = try #require(union.last?.snapshot)
        library.toggleLike(snapshot: lazySnapshot)
        #expect(library.likedSnapshotIDs(for: [lazySnapshot]) == [lazySnapshot.id])
        let verify = ModelContext(container)
        #expect(try verify.fetchCount(FetchDescriptor<Track>()) == 3)
        #expect(try verify.fetch(FetchDescriptor<YouTubeImportItem>())
            .first(where: { $0.youTubeId == "lazy" })?.track?.liked == true)
        library.toggleLike(snapshot: lazySnapshot)
        #expect(library.likedSnapshotIDs(for: [lazySnapshot]).isEmpty)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Track>()) == 3)
    }

    @Test("Clearing deleted playlists removes recovery records while retaining tracks")
    func clearRecovery() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let track = Track(title: "Keep", artist: "Artist", youTubeId: "keep")
        context.insert(track)
        let imported = YouTubeImport(playlistId: "PL-test", url: "https://youtube.com/playlist?list=PL-test",
                                     title: "Imported", channel: "Artist")
        context.insert(imported)
        let item = YouTubeImportItem(youTubeId: "keep", title: "Keep", artist: "Artist")
        context.insert(item)
        item.import_ = imported
        item.track = track
        imported.items = [item]
        try context.save()
        let id = imported.id
        let service = YouTubePlaylistSyncService(modelContainer: container,
            account: YouTubeAccountService(session: GoogleOAuthSession(keychain: InMemoryKeychain())))
        #expect(throws: YouTubePlaylistSyncError.self) {
            try service.permanentlyDeleteLocalImports(ids: [id])
        }
        try service.moveToRecentlyDeleted(importID: id)
        #expect(!(try service.revisions(importID: id)).isEmpty)
        let journalContext = ModelContext(container)
        let batch = YouTubeSyncBatch(importID: id, accountChannelID: nil,
            playlistID: "PL-test", baseRevisionID: UUID(), localRevisionID: UUID(),
            remoteRevisionID: UUID(), expectedRemoteFingerprint: "test",
            desiredSnapshotData: Data(), preRemoteSnapshotData: Data())
        batch.state = .started
        journalContext.insert(batch)
        try journalContext.save()
        #expect(throws: YouTubePlaylistSyncError.self) {
            try service.permanentlyDeleteLocalImports(ids: [id])
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<YouTubeImport>()) == 1)
        batch.state = .locallyCommitted
        try journalContext.save()
        try service.permanentlyDeleteLocalImports(ids: [id])
        let verify = ModelContext(container)
        #expect(try verify.fetchCount(FetchDescriptor<YouTubeImport>()) == 0)
        #expect(try verify.fetchCount(FetchDescriptor<YouTubeImportItem>()) == 0)
        #expect(try verify.fetchCount(FetchDescriptor<YouTubePlaylistRevision>()) == 0)
        #expect(try verify.fetchCount(FetchDescriptor<YouTubeSyncBatch>()) == 0)
        #expect(try verify.fetchCount(FetchDescriptor<Track>()) == 1)
    }
}
