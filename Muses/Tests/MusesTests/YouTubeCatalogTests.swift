import Foundation
import SwiftData
import Testing
@testable import Muses

@MainActor
@Suite("YouTube catalog identity", .serialized)
struct YouTubeCatalogTests {
    @Test("release identity requires a stable browse or playlist id")
    func releaseIdentityRequiresStableID() {
        #expect(YouTubeCatalogIdentity.release(browseID: "MPREb_123", playlistID: nil)
                == "browse:MPREb_123")
        #expect(YouTubeCatalogIdentity.release(browseID: nil, playlistID: "OLAK5uy_123")
                == "playlist:OLAK5uy_123")
        #expect(YouTubeCatalogIdentity.release(browseID: "  ", playlistID: "") == nil)
    }

    @Test("artist identity never falls back to display name")
    func artistIdentityNeverUsesName() {
        #expect(YouTubeCatalogIdentity.artist(channelID: "UC_one", browseID: nil)
                == "channel:UC_one")
        #expect(YouTubeCatalogIdentity.artist(channelID: nil, browseID: "UC_two")
                == "browse:UC_two")
        #expect(YouTubeCatalogIdentity.artist(channelID: nil, browseID: nil) == nil)
    }

    @Test("catalog and remote-item menu links preserve stable YouTube identity")
    func contextMenuLinks() {
        #expect(YouTubeCatalogLink.releaseURL(stableID: "playlist:OLAK5uy_123")?.absoluteString
            == "https://music.youtube.com/playlist?list=OLAK5uy_123")
        #expect(YouTubeCatalogLink.releaseURL(stableID: "browse:MPREb_123")?.absoluteString
            == "https://music.youtube.com/browse/MPREb_123")
        #expect(YouTubeCatalogLink.artistURL(stableID: "channel:UC_123")?.absoluteString
            == "https://music.youtube.com/channel/UC_123")
        #expect(YouTubeContextMenuLink.watchURL(videoID: "video id")?.absoluteString
            == "https://music.youtube.com/watch?v=video%20id")
        #expect(YouTubeCatalogLink.releaseURL(stableID: "Release Name") == nil)
        #expect(YouTubeContextMenuLink.watchURL(videoID: "  ") == nil)
    }

    @Test("same display name with different stable ids remains distinct")
    func sameNameArtistsRemainDistinct() throws {
        let container = try makeModelContainer(inMemory: true)
        let service = YouTubeCatalogService(modelContainer: container)

        service.upsertArtist(stableID: "channel:UC_one", name: "Aster")
        service.upsertArtist(stableID: "channel:UC_two", name: "Aster")

        let artists = service.artists()
        #expect(artists.count == 2)
        #expect(Set(artists.map(\.stableID)) == ["channel:UC_one", "channel:UC_two"])
    }

    @Test("music-video rows retain their Track media kind")
    func trackMediaKindIsPreserved() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let song = Track(title: "Song", artist: "Artist",
                         youTubeId: "song-id")
        let video = Track(title: "Video", artist: "Artist",
                          youTubeId: "video-id", mediaKind: .musicVideo)
        context.insert(song)
        context.insert(video)
        try context.save()

        #expect(song.mediaKind == .song)
        #expect(video.mediaKind == .musicVideo)
    }

    @Test("release membership uses stable id and canonical track order")
    func releaseProjectionOrder() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let second = Track(title: "Second", artist: "Artist",
                           youTubeId: "v2", releaseCatalogID: "playlist:OLAK", releaseOrder: 1)
        let first = Track(title: "First", artist: "Artist",
                          youTubeId: "v1", releaseCatalogID: "playlist:OLAK", releaseOrder: 0)
        context.insert(second)
        context.insert(first)
        context.insert(CatalogRelease(stableID: "playlist:OLAK", title: "Release",
                                      artistName: "Artist"))
        try context.save()

        let release = try #require(
            YouTubeCatalogService(modelContainer: container).releases().first)
        #expect(release.stableID == "playlist:OLAK")
        #expect(release.tracks.map(\.title) == ["First", "Second"])
    }

    @Test("orphan release cache rows are hidden and reconciled without deleting tracks")
    func orphanReleaseCacheIsPruned() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let liveTrack = Track(
                        title: "Live",
            artist: "Artist",
            youTubeId: "live-video",
            releaseCatalogID: "playlist:OLAK_live",
            releaseOrder: 0
        )
        context.insert(liveTrack)
        context.insert(CatalogRelease(
            stableID: "playlist:OLAK_live",
            title: "Live Release",
            artistName: "Artist"
        ))
        context.insert(CatalogRelease(
            stableID: "playlist:OLAK_orphan",
            title: "Removed Release",
            artistName: "Artist"
        ))
        try context.save()

        let service = YouTubeCatalogService(modelContainer: container)
        #expect(service.releases().map(\.stableID) == ["playlist:OLAK_live"])

        service.rebuildFromTrackMetadata()

        let verify = ModelContext(container)
        #expect(try verify.fetch(FetchDescriptor<CatalogRelease>()).map(\.stableID)
            == ["playlist:OLAK_live"])
        #expect(try verify.fetch(FetchDescriptor<Track>()).map(\.id) == [liveTrack.id])
    }
}
