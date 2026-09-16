import Foundation
import SwiftData
import Testing
@testable import Muses

@MainActor
@Suite("YouTube catalog identity", .serialized)
struct YouTubeCatalogTests {
    @Test("legacy names are quarantined without rewriting tracks or deleting history fields")
    func legacyNamesRemainUnresolved() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let track = Track(title: "Song", artist: "Same Name", albumTitle: "Same Album",
                          youTubeId: "abcdefghijk", liked: true,
                          releaseCatalogID: "album:same name:same album", artistCatalogID: "artist:same name")
        context.insert(track)
        context.insert(CatalogArtist(stableID: "artist:same name", name: "Same Name"))
        context.insert(CatalogRelease(stableID: "album:same name:same album", title: "Same Album", artistName: "Same Name"))
        try context.save()
        let service = YouTubeCatalogService(modelContainer: container)
        service.rebuildFromTrackMetadata()
        #expect(service.artists().isEmpty)
        #expect(service.releases().isEmpty)
        let verify = ModelContext(container)
        let saved = try #require(verify.fetch(FetchDescriptor<Track>()).first)
        #expect(saved.id == track.id)
        #expect(saved.liked)
        #expect(saved.albumTitle == "Same Album")
        #expect(saved.artistCatalogID == "artist:same name")
        #expect(saved.releaseCatalogID == "album:same name:same album")
        #expect(try verify.fetchCount(FetchDescriptor<CatalogArtist>()) == 1)
        #expect(try verify.fetchCount(FetchDescriptor<CatalogRelease>()) == 1)
    }

    @Test("online catalog import rejects non-video entries and name-derived release IDs")
    func invalidOnlineImports() throws {
        let container = try makeModelContainer(inMemory: true)
        let service = YouTubeCatalogService(modelContainer: container)
        #expect(throws: YouTubeImportError.invalidURL) {
            try service.importOnlineTrack(entry: .init(id: "UCabcdefghijklmnopqrstuv", title: "Channel"))
        }
        #expect(throws: YouTubeImportError.invalidURL) {
            try service.importOnlineTrack(entry: .init(id: "abcdefghijk", title: "Song"), releaseStableID: "album:artist:title")
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Track>()) == 0)
    }

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
        #expect(service.artist(byName: "Aster") == nil)
        #expect(service.artist(byStableID: "channel:UC_one")?.stableID == "channel:UC_one")
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

    @Test("lookup helpers resolve releases and artists by stableID or name")
    func lookupHelpers() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let track = Track(
            title: "Song",
            artist: "Dua Lipa",
            albumTitle: "Future Nostalgia",
            youTubeId: "dua123",
            releaseCatalogID: "playlist:OLAK_future",
            artistCatalogID: "channel:UC_dua"
        )
        context.insert(track)
        context.insert(CatalogRelease(
            stableID: "playlist:OLAK_future",
            title: "Future Nostalgia",
            artistName: "Dua Lipa",
            artistStableID: "channel:UC_dua"
        ))
        context.insert(CatalogArtist(
            stableID: "channel:UC_dua",
            name: "Dua Lipa",
            channelID: "UC_dua"
        ))
        try context.save()

        let service = YouTubeCatalogService(modelContainer: container)
        #expect(service.release(byStableID: "playlist:OLAK_future")?.title == "Future Nostalgia")
        #expect(service.release(byTitle: "future nostalgia")?.stableID == "playlist:OLAK_future")
        #expect(service.artist(byStableID: "channel:UC_dua")?.name == "Dua Lipa")
        #expect(service.artist(byName: "dua lipa")?.stableID == "channel:UC_dua")
    }

    @Test("online catalog rejects namesakes and non-album resources and supports refresh")
    func onlineDiscographyFetching() async throws {
        let bridge = MockCatalogBridge()
        bridge.searchResults = [
            .init(id: "abcdefghijk", title: "Song", channelID: "UC_dua"),
            .init(id: "zyxwvutsrqp", title: "Same artist name", channelID: "UC_other"),
            .init(id: "OLAK5uy_album", title: "Album", channelID: "UC_dua"),
            .init(id: "PL_user_playlist", title: "Album", channelID: "UC_dua")
        ]
        let service = YouTubeCatalogService(modelContainer: try makeModelContainer(inMemory: true), bridge: bridge)
        let artist = CatalogArtistProjection(stableID: "channel:UC_dua", name: "Dua Lipa",
            artworkURL: nil, biography: nil, cacheState: .fresh, releases: [], tracks: [])
        let disco = try await service.fetchArtistOnlineDiscography(artist: artist)
        #expect(disco.topTracks.map(\.id) == ["abcdefghijk"])
        #expect(disco.albums.map(\.playlistID) == ["OLAK5uy_album"])
        #expect(disco.singlesAndEPs.isEmpty)
        #expect(try await service.fetchArtistOnlineDiscography(artist: artist) == disco)
        #expect(bridge.searchCallCount == 1)
        bridge.searchResults = []
        #expect(try await service.fetchArtistOnlineDiscography(artist: artist, forceRefresh: true).isEmpty)
        #expect(bridge.searchCallCount == 2)
        #expect(bridge.invalidationCount == 1)
    }

    @Test("importing online track and album attaches release and artist catalog IDs")
    func importOnlineTrackAndAlbum() throws {
        let container = try makeModelContainer(inMemory: true)
        let service = YouTubeCatalogService(modelContainer: container)

        let entry = YTDlpBridge.YTDlpPlaylistEntry(
            id: "onlineSong1",
            title: "Physical",
            uploader: "Dua Lipa",
            duration: 195,
            channelID: "UC_dua"
        )
        let snapshot = try service.importOnlineTrack(
            entry: entry,
            releaseStableID: "playlist:OLAK_future",
            order: 0,
            albumTitle: "Future Nostalgia",
            artistName: "Dua Lipa"
        )

        #expect(snapshot.youTubeId == "onlineSong1")
        #expect(snapshot.title == "Physical")

        let verify = ModelContext(container)
        let tracks = try verify.fetch(FetchDescriptor<Track>())
        #expect(tracks.count == 1)
        #expect(tracks.first?.releaseCatalogID == "playlist:OLAK_future")
        #expect(tracks.first?.artistCatalogID == "channel:UC_dua")
    }

    @Test("missing catalog identities stay unresolved without name-based grouping")
    func autoCatalogFromTracksAndPlaylists() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)

        // Song with album title
        let song1 = Track(
            title: "Style",
            artist: "Taylor Swift",
            albumTitle: "1989",
            youTubeId: "style_yt"
        )
        // Another song on the same album
        let song2 = Track(
            title: "Blank Space",
            artist: "Taylor Swift",
            albumTitle: "1989",
            youTubeId: "blank_space_yt"
        )
        // Standalone song with no album (single)
        let song3 = Track(
            title: "Anti-Hero",
            artist: "Taylor Swift",
            youTubeId: "antihero_yt"
        )
        // Song by different artist
        let song4 = Track(
            title: "Yellow",
            artist: "Coldplay",
            albumTitle: "Parachutes",
            youTubeId: "yellow_yt"
        )
        context.insert(song1)
        context.insert(song2)
        context.insert(song3)
        context.insert(song4)
        try context.save()

        let service = YouTubeCatalogService(modelContainer: container)

        service.rebuildFromTrackMetadata()
        #expect(service.releases().isEmpty)
        #expect(service.artists().isEmpty)
        #expect(service.unresolvedCounts().releases == 4)
        #expect(service.unresolvedCounts().artists == 4)
        let persisted = try ModelContext(container).fetch(FetchDescriptor<Track>())
        #expect(persisted.count == 4)
        #expect(persisted.allSatisfy { $0.artistCatalogID == nil && $0.releaseCatalogID == nil })

    }

    @Test("projection rebuild does not backfill historical import relationships")
    func importedPlaylistCataloged() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)

        // Historical album membership is evidence for a preview, not permission to mutate.
        let albumImp = YouTubeImport(
            playlistId: "OLAK5uy_custom_album",
            url: "https://music.youtube.com/playlist?list=OLAK5uy_custom_album",
            title: "Rock Hits Album",
            channel: "Rock Band"
        )
        context.insert(albumImp)

        let item1 = YouTubeImportItem(
            youTubeId: "rock1",
            title: "Rock Song 1",
            artist: "Rock Band",
            durationMs: 200000,
            order: 0
        )
        item1.import_ = albumImp
        context.insert(item1)

        // Regular playlist membership supplies no release identity.
        let plImp = YouTubeImport(
            playlistId: "PL_regular_playlist",
            url: "https://youtube.com/playlist?list=PL_regular_playlist",
            title: "My Liked Playlist",
            channel: "shiachishenm"
        )
        context.insert(plImp)

        let item2 = YouTubeImportItem(
            youTubeId: "song2",
            title: "Pop Song 2",
            artist: "Pop Singer",
            durationMs: 180000,
            order: 0
        )
        item2.import_ = plImp
        context.insert(item2)

        try context.save()

        let service = YouTubeCatalogService(modelContainer: container)
        service.rebuildFromTrackMetadata()

        let releases = service.releases()
        #expect(releases.isEmpty)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Track>()) == 0)
        // Regular playlist does NOT appear as a release
        #expect(!releases.contains(where: { $0.title == "My Liked Playlist" }))
        // A video without an authoritative release ID remains in Songs.
        #expect(!releases.contains(where: { $0.title == "Pop Song 2" }))

        let artists = service.artists()
        #expect(!artists.contains(where: { $0.name == "Rock Band" }))
        #expect(!artists.contains(where: { $0.name == "Pop Singer" }))
        #expect(!artists.contains(where: { $0.name == "shiachishenm" }))
    }

    @Test("custom stable IDs produce valid links in YouTubeCatalogLink")
    func customStableIDLinks() {
        #expect(YouTubeCatalogLink.releaseURL(stableID: "single:vid123")?.absoluteString
            == "https://music.youtube.com/watch?v=vid123")
        #expect(YouTubeCatalogLink.releaseURL(stableID: "album:taylor swift:1989")?.query
            == "q=taylor%20swift%201989")
        #expect(YouTubeCatalogLink.artistURL(stableID: "artist:coldplay")?.query
            == "q=coldplay")
    }
}

@MainActor
private final class MockCatalogBridge: YTDlpBridgeProtocol {
    var entries: [YTDlpBridge.YTDlpPlaylistEntry] = []
    var fetchCallCount = 0
    var searchResults: [YTDlpBridge.YTDlpPlaylistEntry] = []
    var searchCallCount = 0
    var invalidationCount = 0
    func invalidateSearch(query: String, limit: Int) { invalidationCount += 1 }

    func resolveStreamURL(videoId: String, quality: String, timeout: TimeInterval) async throws -> URL {
        URL(string: "https://example.com/audio")!
    }

    func fetchPlaylist(url: String, timeout: TimeInterval) async throws -> [YTDlpBridge.YTDlpPlaylistEntry] {
        fetchCallCount += 1
        return entries
    }

    func searchYouTube(query: String, limit: Int, timeout: TimeInterval) async throws -> [YTDlpBridge.YTDlpPlaylistEntry] {
        searchCallCount += 1
        return searchResults
    }

    func version() async -> String? { "mock" }
}
