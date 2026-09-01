import Testing
import Foundation
import SwiftData
@testable import Muses

@MainActor
@Suite("YouTubeImportService", .serialized)
struct YouTubeImportServiceTests {

    // MARK: - 1. importPlaylist creates import + items + tracks

    @Test("importPlaylist 创建 import + items + tracks")
    func importPlaylistCreatesEntities() async throws {
        let container = try makeModelContainer(inMemory: true)
        let bridge = MockImportBridge()
        bridge.entries = [
            YTDlpBridge.YTDlpPlaylistEntry(
                id: "v1", title: "Song A", uploader: "Chan", duration: 201.5),
            YTDlpBridge.YTDlpPlaylistEntry(
                id: "v2", title: "Song B", uploader: "Chan", duration: 180.0),
        ]

        let service = makeService(bridge: bridge, container: container)

        let importId = try await service.importPlaylist(
            url: "https://www.youtube.com/playlist?list=PLtest123")

        // Returns a non-empty UUID.
        #expect(importId != UUID())

        // Verify the bridge was called exactly once.
        #expect(bridge.fetchCallCount == 1)

        // Verify persistence with a fresh context.
        let verifyCtx = ModelContext(container)
        let imports = try verifyCtx.fetch(FetchDescriptor<YouTubeImport>())
        #expect(imports.count == 1)
        let imp = try #require(imports.first)
        #expect(imp.playlistId == "PLtest123")
        #expect(imp.url == "https://www.youtube.com/playlist?list=PLtest123")
        #expect(imp.channel == "Chan")
        #expect(imp.title == "YouTube Playlist")
        #expect(imp.lastSyncedAt != nil)

        let sortedItems = (imp.items ?? []).sorted { $0.order < $1.order }
        #expect(sortedItems.count == 2)
        #expect(sortedItems[0].youTubeId == "v1")
        #expect(sortedItems[0].order == 0)
        #expect(sortedItems[0].title == "Song A")
        #expect(sortedItems[0].artist == "Chan")
        #expect(sortedItems[0].durationMs == 201500)
        #expect(sortedItems[1].youTubeId == "v2")
        #expect(sortedItems[1].order == 1)
        #expect(sortedItems[1].durationMs == 180000)

        // Track: source .youtube, correct youTubeId, artworkUrl points at the thumbnail.
        let tracks = try verifyCtx.fetch(FetchDescriptor<Track>())
        #expect(tracks.count == 2)
        let v1Track = try #require(tracks.first { $0.youTubeId == "v1" })
        #expect(v1Track.title == "Song A")
        #expect(v1Track.artworkUrl == "https://i.ytimg.com/vi/v1/hqdefault.jpg")
        let v2Track = try #require(tracks.first { $0.youTubeId == "v2" })
        #expect(v2Track.artworkUrl == "https://i.ytimg.com/vi/v2/hqdefault.jpg")

        // import.artworkUrl points at the first video's thumbnail.
        #expect(imp.artworkUrl == "https://i.ytimg.com/vi/v1/hqdefault.jpg")

        // item.track is linked.
        #expect(sortedItems[0].track?.youTubeId == "v1")
        #expect(sortedItems[1].track?.youTubeId == "v2")
    }

    // MARK: - 2. Edge cases: empty playlist / invalid URL

    @Test("空歌单抛 emptyPlaylist")
    func emptyPlaylistThrows() async throws {
        let container = try makeModelContainer(inMemory: true)
        let bridge = MockImportBridge()
        bridge.entries = []
        let service = makeService(bridge: bridge, container: container)

        await #expect(throws: YouTubeImportError.self) {
            _ = try await service.importPlaylist(
                url: "https://www.youtube.com/playlist?list=PLempty")
        }
    }

    @Test("缺少 list 参数抛 invalidURL")
    func missingListParamThrowsInvalidURL() async throws {
        let container = try makeModelContainer(inMemory: true)
        let bridge = MockImportBridge()
        bridge.entries = [
            YTDlpBridge.YTDlpPlaylistEntry(
                id: "x1", title: "X", uploader: "C", duration: 10.0),
        ]
        let service = makeService(bridge: bridge, container: container)

        await #expect(throws: YouTubeImportError.self) {
            _ = try await service.importPlaylist(url: "https://www.youtube.com/watch?v=x1")
        }
    }

    @Test("再次导入同一 playlistId 复用本地状态且不隐式检查远端")
    func reimportSamePlaylistReusesTracks() async throws {
        let container = try makeModelContainer(inMemory: true)
        let bridge = MockImportBridge()
        bridge.entries = [
            YTDlpBridge.YTDlpPlaylistEntry(
                id: "v1", title: "Song A", uploader: "Chan", duration: 10),
            YTDlpBridge.YTDlpPlaylistEntry(
                id: "v2", title: "Song B", uploader: "Chan", duration: 12),
        ]
        let service = makeService(bridge: bridge, container: container)
        let url = "https://www.youtube.com/playlist?list=PLreuse"
        let first = try await service.importPlaylist(url: url)
        let second = try await service.importPlaylist(url: url)
        #expect(first == second)
        let verify = ModelContext(container)
        #expect(try verify.fetch(FetchDescriptor<YouTubeImport>()).count == 1)
        #expect(try verify.fetch(FetchDescriptor<Track>()).count == 2)
        #expect(bridge.fetchCallCount == 1)
    }

    @Test("oEmbed 失败时使用 yt-dlp playlist_title")
    func importUsesPlaylistTitleFallback() async throws {
        let container = try makeModelContainer(inMemory: true)
        let bridge = MockImportBridge()
        bridge.entries = [
            YTDlpBridge.YTDlpPlaylistEntry(
                id: "v1", title: "Song A", uploader: "Chan", duration: 10,
                playlistTitle: "Triumph on the Ice"),
        ]
        let service = makeService(bridge: bridge, container: container)
        _ = try await service.importPlaylist(
            url: "https://www.youtube.com/playlist?list=PLtitle")
        let imp = try #require(ModelContext(container).fetch(FetchDescriptor<YouTubeImport>()).first)
        #expect(imp.title == "Triumph on the Ice")
        #expect(try ModelContext(container).fetch(FetchDescriptor<CatalogRelease>()).isEmpty)
        #expect(try ModelContext(container).fetch(FetchDescriptor<CatalogArtist>()).isEmpty)
    }

    @Test("repairYouTubeLibrary 合并同 youTubeId 且不按文本创建目录身份")
    func repairMergesDuplicateYouTubeTracks() async throws {
        let container = try makeModelContainer(inMemory: true)
        let bridge = MockImportBridge()
        bridge.entries = [
            YTDlpBridge.YTDlpPlaylistEntry(
                id: "v1", title: "Song A", uploader: "Chan", duration: 10),
        ]
        let service = makeService(bridge: bridge, container: container)
        _ = try await service.importPlaylist(
            url: "https://www.youtube.com/playlist?list=PLdup")

        let ctx = ModelContext(container)
        let original = try #require(ctx.fetch(FetchDescriptor<Track>()).first)
        original.playCount = 2
        let dupe1 = Track(title: "Song A", artist: "Chan",
                          durationMs: 10000, youTubeId: "v1")
        dupe1.playCount = 3
        dupe1.liked = true
        dupe1.lastPlayedAt = Date()
        ctx.insert(dupe1)
        let dupe2 = Track(title: "Song A", artist: "Chan",
                          durationMs: 10000, youTubeId: "v1")
        dupe2.playCount = 1
        ctx.insert(dupe2)
        try ctx.save()

        service.repairYouTubeLibrary()

        let verify = ModelContext(container)
        let tracks = try verify.fetch(FetchDescriptor<Track>())
        #expect(tracks.count == 1)
        let kept = try #require(tracks.first)
        #expect(kept.playCount == 6)
        #expect(kept.liked == true)
        #expect(kept.releaseCatalogID == nil)
        #expect(try verify.fetch(FetchDescriptor<CatalogRelease>()).isEmpty)
        #expect(try verify.fetch(FetchDescriptor<CatalogArtist>()).isEmpty)
    }

    @Test("YouTube Music OLAK5uy 通过稳定 ID 创建目录专辑和艺术家")
    func musicAlbumPlaylistCreatesAlbum() async throws {
        let container = try makeModelContainer(inMemory: true)
        let bridge = MockImportBridge()
        bridge.entries = [
            YTDlpBridge.YTDlpPlaylistEntry(
                id: "v1", title: "Song A", uploader: "Chan", duration: 10,
                playlistTitle: "Ice Album", channelID: "UCice",
                track: "Song A", album: "Ice Album", releaseYear: 2026),
            YTDlpBridge.YTDlpPlaylistEntry(
                id: "v2", title: "Song B (Official Music Video)", uploader: "Chan", duration: 12,
                playlistTitle: "Ice Album", channelID: "UCice"),
        ]
        let service = makeService(bridge: bridge, container: container)
        _ = try await service.importPlaylist(
            url: "https://music.youtube.com/playlist?list=OLAK5uy_abc123")

        let context = ModelContext(container)
        let releases = try context.fetch(FetchDescriptor<CatalogRelease>())
        let release = try #require(releases.first)
        #expect(releases.count == 1)
        #expect(release.stableID == "playlist:OLAK5uy_abc123")
        #expect(release.title == "Ice Album")
        #expect(release.artistName == "Chan")
        #expect(release.artistStableID == "channel:UCice")

        let artists = try context.fetch(FetchDescriptor<CatalogArtist>())
        let artist = try #require(artists.first)
        #expect(artists.count == 1)
        #expect(artist.stableID == "channel:UCice")
        #expect(artist.channelID == "UCice")
        #expect(artist.name == "Chan")

        let tracks = try context.fetch(FetchDescriptor<Track>())
        let song = try #require(tracks.first { $0.youTubeId == "v1" })
        let video = try #require(tracks.first { $0.youTubeId == "v2" })
        #expect(song.releaseCatalogID == release.stableID)
        #expect(video.releaseCatalogID == release.stableID)
        #expect(song.artistCatalogID == artist.stableID)
        #expect(video.artistCatalogID == artist.stableID)
        #expect(song.releaseOrder == 0)
        #expect(video.releaseOrder == 1)
        #expect(song.mediaKind == .song)
        #expect(video.mediaKind == .musicVideo)
    }

    // MARK: - Factory

    /// Builds a service with a temporary ArtworkCache + a short-timeout ephemeral session (with no stub rules,
    /// network requests fail fast, so artwork downloads do not block and nothing is written to disk).
    private func makeService(bridge: MockImportBridge,
                             container: ModelContainer,
                             catalog: YouTubeCatalogService? = nil) -> YouTubeImportService {
        YouTubeImportServiceStub.reset()
        let stub = YouTubeImportServiceStub()
        // Return 404 for every request — artwork downloads fail as non-2xx and never reach the cache.
        stub.respond(forHostContaining: "") { _ in
            StubResponse(statusCode: 404, body: Data())
        }
        let session = URLSession(configuration: YouTubeImportServiceStub.makeConfig())
        let artworkCache = ArtworkCache(
            directory: FileManager.default.temporaryDirectory
                .appending(path: "muses-yt-import-\(UUID().uuidString)"))
        return YouTubeImportService(
            bridge: bridge,
            modelContainer: container,
            artworkCache: artworkCache,
            session: session,
            catalog: catalog
        )
    }
}

// MARK: - Mock bridge

@MainActor
final class MockImportBridge: YTDlpBridgeProtocol {
    var entries: [YTDlpBridge.YTDlpPlaylistEntry] = []
    var fetchCallCount = 0
    var searchResults: [YTDlpBridge.YTDlpPlaylistEntry] = []
    var searchCallCount = 0

    func resolveStreamURL(videoId: String, quality: String, timeout: TimeInterval) async throws -> URL {
        URL(string: "https://example.com/a")!
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
final class YouTubeImportServiceStub: StubURLProtocolBase, @unchecked Sendable {
    nonisolated(unsafe) private static var _rules: [StubRule] = []
    private static let _lock = NSLock()
    override class var rules: [StubRule] {
        get { _rules } set { _rules = newValue }
    }
    override class var lock: NSLock { _lock }
}
