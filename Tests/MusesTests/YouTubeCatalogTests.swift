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

    @Test("online discography fetches and partitions releases into albums and singles")
    func onlineDiscographyFetching() async throws {
        let container = try makeModelContainer(inMemory: true)
        let bridge = MockCatalogBridge()
        bridge.searchResults = [
            YTDlpBridge.YTDlpPlaylistEntry(id: "top1", title: "Levitating", uploader: "Dua Lipa", duration: 203)
        ]
        bridge.entries = [
            YTDlpBridge.YTDlpPlaylistEntry(id: "OLAK_album", title: "Future Nostalgia", releaseYear: 2020),
            YTDlpBridge.YTDlpPlaylistEntry(id: "OLAK_single", title: "Don't Start Now - Single", releaseYear: 2019)
        ]

        let service = YouTubeCatalogService(modelContainer: container, bridge: bridge)
        let artist = CatalogArtistProjection(
            stableID: "channel:UC_dua",
            name: "Dua Lipa",
            artworkURL: nil,
            biography: nil,
            cacheState: .fresh,
            releases: [],
            tracks: []
        )

        let disco = try await service.fetchArtistOnlineDiscography(artist: artist)
        #expect(disco.topTracks.count == 1)
        #expect(disco.topTracks.first?.id == "top1")
        #expect(disco.albums.count == 1)
        #expect(disco.albums.first?.playlistID == "OLAK_album")
        #expect(disco.singlesAndEPs.count == 1)
        #expect(disco.singlesAndEPs.first?.playlistID == "OLAK_single")

        // Second call should hit the cache without calling bridge again
        let cached = try await service.fetchArtistOnlineDiscography(artist: artist)
        #expect(cached == disco)
        #expect(bridge.fetchCallCount == 1)
    }

    @Test("importing online track and album attaches release and artist catalog IDs")
    func importOnlineTrackAndAlbum() throws {
        let container = try makeModelContainer(inMemory: true)
        let service = YouTubeCatalogService(modelContainer: container)

        let entry = YTDlpBridge.YTDlpPlaylistEntry(
            id: "online_song_1",
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

        #expect(snapshot.youTubeId == "online_song_1")
        #expect(snapshot.title == "Physical")

        let verify = ModelContext(container)
        let tracks = try verify.fetch(FetchDescriptor<Track>())
        #expect(tracks.count == 1)
        #expect(tracks.first?.releaseCatalogID == "playlist:OLAK_future")
        #expect(tracks.first?.artistCatalogID == "channel:UC_dua")
    }

    @Test("tracks without catalog IDs are auto-cataloged into artists, albums, and singles")
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

        let releases = service.releases()
        #expect(releases.count == 3) // 1989 (album), Parachutes (album), Anti-Hero (single)

        let album1989 = try #require(service.release(byTitle: "1989"))
        #expect(album1989.artistName == "Taylor Swift")
        #expect(album1989.tracks.count == 2)
        #expect(album1989.kind == .album)

        let yellowAlbum = try #require(service.release(byTitle: "Parachutes"))
        #expect(yellowAlbum.artistName == "Coldplay")
        #expect(yellowAlbum.tracks.count == 1)

        let antiHeroSingle = try #require(service.release(byTitle: "Anti-Hero"))
        #expect(antiHeroSingle.kind == .single)

        let artists = service.artists()
        #expect(artists.count == 2) // Taylor Swift, Coldplay

        let taylor = try #require(service.artist(byName: "Taylor Swift"))
        #expect(taylor.tracks.count == 3) // Style, Blank Space, Anti-Hero
        #expect(taylor.releases.count >= 1)

        let coldplay = try #require(service.artist(byName: "Coldplay"))
        #expect(coldplay.tracks.count == 1)
    }

    @Test("tracks in imported playlist are cataloged with playlist release only if it is a music album")
    func importedPlaylistCataloged() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)

        // 1. Official YouTube Music album import (OLAK5uy...) -> becomes an album release
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

        // 2. Regular user playlist import (PL...) -> does NOT become an album release; tracks become singles
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
        // Official album appears as a release
        #expect(releases.contains(where: { $0.title == "Rock Hits Album" }))
        // Regular playlist does NOT appear as a release
        #expect(!releases.contains(where: { $0.title == "My Liked Playlist" }))
        // The track from the regular playlist appears as its own single
        #expect(releases.contains(where: { $0.title == "Pop Song 2" && $0.kind == .single }))

        let artists = service.artists()
        #expect(artists.contains(where: { $0.name == "Rock Band" }))
        #expect(artists.contains(where: { $0.name == "Pop Singer" }))
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

