import Foundation
import SwiftData
import Testing
@testable import Muses

@MainActor
@Suite("Historical catalog identity preview", .serialized)
struct CatalogIdentityPreviewTests {
    @Test("Preview retains repeated evidence, isolates duplicate UUIDs, and performs no writes")
    func repeatedEvidence() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let track = Track(title: "Song", artist: "Uploader", youTubeId: "abcdefghijk", liked: true)
        let duplicate = Track(title: "Song", artist: "Uploader", youTubeId: "abcdefghijk")
        context.insert(track)
        context.insert(duplicate)
        context.insert(TrackNote(trackId: track.id, content: "Untouched"))
        let owner = YouTubeImport(playlistId: "OLAK5uy_album", url: "https://music.youtube.com/playlist?list=OLAK5uy_album", title: "Album", channel: "Uploader")
        context.insert(owner)
        for order in [0, 3] {
            let item = YouTubeImportItem(youTubeId: track.youTubeId, title: "Song", artist: "Uploader", order: order)
            item.import_ = owner
            item.track = track
            context.insert(item)
        }
        try context.save()
        let preview = try CatalogIdentityPreview.read(from: container)
        let repeated = try CatalogIdentityPreview.read(from: container)
        #expect(preview == repeated)
        let row = try #require(preview.rows.first { $0.id == track.id })
        #expect(row.resolution == .proposed("playlist:OLAK5uy_album"))
        #expect(row.evidence.map(\.order) == [0, 3])
        #expect(Set(row.evidence.map(\.itemID)).count == 2)
        #expect(preview.rows.first { $0.id == duplicate.id }?.resolution == .unresolved)
        let verify = ModelContext(container)
        let saved = try verify.fetch(FetchDescriptor<Track>())
        #expect(Set(saved.map(\.id)) == Set([track.id, duplicate.id]))
        #expect(saved.allSatisfy { $0.releaseCatalogID == nil && $0.artistCatalogID == nil })
        #expect(saved.first { $0.id == track.id }?.liked == true)
        #expect(try verify.fetch(FetchDescriptor<TrackNote>()).first?.content == "Untouched")
        #expect(try verify.fetchCount(FetchDescriptor<CatalogRelease>()) == 0)
    }

    @Test("Multiple releases stay ambiguous and established identities are never replaced")
    func ambiguousEvidence() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let track = Track(title: "Same Name", artist: "Same Name", youTubeId: "abcdefghijk")
        context.insert(track)
        for playlistID in ["OLAK5uy_one", "OLAK5uy_two", "PLordinary"] {
            let owner = YouTubeImport(playlistId: playlistID, url: "https://youtube.com/playlist?list=\(playlistID)", title: "Same Name", channel: "Same Name")
            context.insert(owner)
            let item = YouTubeImportItem(youTubeId: "abcdefghijk", title: "Same Name", artist: "Same Name")
            item.import_ = owner
            item.track = track
            context.insert(item)
        }
        try context.save()
        let preview = try CatalogIdentityPreview.read(from: container)
        #expect(preview.rows.first?.resolution == .ambiguous)
        #expect(preview.rows.first?.evidence.count == 2)
        track.releaseCatalogID = "browse:existing"
        try context.save()
        #expect(try CatalogIdentityPreview.read(from: container).rows.first?.resolution == .alreadyResolved)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Track>()).first?.releaseCatalogID == "browse:existing")
    }

    @Test("Malformed and mismatched video relationships cannot supply evidence")
    func invalidEvidence() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let owner = YouTubeImport(playlistId: "OLAK5uy_album", url: "https://music.youtube.com/playlist?list=OLAK5uy_album", title: "Album", channel: "Uploader")
        context.insert(owner)
        for (videoID, itemVideoID) in [("short", "short"), ("abcdefghijk", "lmnopqrstuv")] {
            let track = Track(title: "Song", artist: "Uploader", youTubeId: videoID)
            context.insert(track)
            let item = YouTubeImportItem(youTubeId: itemVideoID, title: "Song", artist: "Uploader")
            item.import_ = owner
            item.track = track
            context.insert(item)
        }
        try context.save()
        let preview = try CatalogIdentityPreview.read(from: container)
        #expect(preview.rows.count == 2)
        #expect(preview.rows.allSatisfy { $0.resolution == .unresolved && $0.evidence.isEmpty })
    }

    @Test("Release type requires source evidence, not a title suffix or one cached track")
    func releaseKindEvidence() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        for (index, title) in ["Song - Single", "Record - EP", "Song"].enumerated() {
            context.insert(Track(title: title, artist: "Artist", albumTitle: title,
                                 youTubeId: "abcdefghijk", releaseCatalogID: "browse:release\(index)"))
        }
        try context.save()
        let catalog = YouTubeCatalogService(modelContainer: container)
        catalog.rebuildFromTrackMetadata()
        #expect(try ModelContext(container).fetch(FetchDescriptor<CatalogRelease>()).allSatisfy { $0.kind == .unknown })
        catalog.upsertRelease(stableID: "browse:release0", title: "Source EP", artistName: "Artist", kind: .ep)
        catalog.rebuildFromTrackMetadata()
        #expect(try ModelContext(container).fetch(FetchDescriptor<CatalogRelease>()).first { $0.stableID == "browse:release0" }?.kind == .ep)
    }
}
