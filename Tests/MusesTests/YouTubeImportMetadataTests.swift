import Testing
import Foundation
import SwiftData
@testable import Muses

/// YouTube oEmbed playlist metadata integration tests.
/// Verifies that importPlaylist / resync fetch real titles/channels/artwork via the oEmbed API,
/// and fall back to placeholder values when oEmbed fails.
@MainActor
@Suite("YouTubeImportMetadata", .serialized)
struct YouTubeImportMetadataTests {

    // MARK: - oEmbed success

    @Test("importPlaylist with successful oEmbed populates title, channel, and artwork")
    func oEmbedSuccessPopulatesMetadata() async throws {
        let container = try makeModelContainer(inMemory: true)
        let bridge = MockImportBridge()
        bridge.entries = [
            YTDlpBridge.YTDlpPlaylistEntry(
                id: "track_oembed_1", title: "Song A", uploader: "Some Channel", duration: 200),
        ]

        YouTubeImportMetadataStub.reset()
        let stub = YouTubeImportMetadataStub()
        // oEmbed request: host contains "youtube.com" and path contains "/oembed"
        stub.respond(forHostContaining: "youtube.com") { req in
            if req.url?.path.contains("/oembed") == true {
                let json = """
                {"title":"My Awesome Playlist","author_name":"Awesome Creator","thumbnail_url":"https://i.ytimg.com/vi/playlist/thumb.jpg"}
                """.data(using: .utf8)!
                return StubResponse(statusCode: 200, body: json,
                                    headers: ["Content-Type": "application/json"])
            }
            // Other requests (artwork downloads etc.) → 404; do not block
            return StubResponse(statusCode: 404, body: Data())
        }
        let session = URLSession(configuration: YouTubeImportMetadataStub.makeConfig())
        let artworkCache = ArtworkCache(
            directory: FileManager.default.temporaryDirectory
                .appending(path: "muses-oembed-\(UUID().uuidString)"))
        let service = YouTubeImportService(
            bridge: bridge, modelContainer: container,
            artworkCache: artworkCache, session: session)

        let importId = try await service.importPlaylist(
            url: "https://www.youtube.com/playlist?list=PLtestOembed")

        let ctx = ModelContext(container)
        let imps = try ctx.fetch(FetchDescriptor<YouTubeImport>())
        #expect(imps.count == 1)
        let imp = try #require(imps.first)
        #expect(imp.id == importId)
        #expect(imp.title == "My Awesome Playlist", "oEmbed title should be populated")
        #expect(imp.channel == "Awesome Creator", "oEmbed channel should be populated")
        #expect(imp.artworkUrl == "https://i.ytimg.com/vi/playlist/thumb.jpg",
                "oEmbed artwork URL should be populated")
    }

    // MARK: - oEmbed failure fallback

    @Test("importPlaylist with oEmbed 404 falls back to placeholder title and channel")
    func oEmbedFailureFallsBack() async throws {
        let container = try makeModelContainer(inMemory: true)
        let bridge = MockImportBridge()
        bridge.entries = [
            YTDlpBridge.YTDlpPlaylistEntry(
                id: "track_oembed_1", title: "Song A", uploader: "Fallback Channel", duration: 200),
        ]

        YouTubeImportMetadataStub.reset()
        let stub = YouTubeImportMetadataStub()
        // Every request returns 404 (oEmbed + artwork all fail)
        stub.respond(forHostContaining: "") { _ in
            StubResponse(statusCode: 404, body: Data())
        }
        let session = URLSession(configuration: YouTubeImportMetadataStub.makeConfig())
        let artworkCache = ArtworkCache(
            directory: FileManager.default.temporaryDirectory
                .appending(path: "muses-oembed-fallback-\(UUID().uuidString)"))
        let service = YouTubeImportService(
            bridge: bridge, modelContainer: container,
            artworkCache: artworkCache, session: session)

        _ = try await service.importPlaylist(
            url: "https://www.youtube.com/playlist?list=PLtestFallback")

        let ctx = ModelContext(container)
        let imp = try #require(try ctx.fetch(FetchDescriptor<YouTubeImport>()).first)
        // Fallback: placeholder title, channel taken from the first entry's uploader.
        #expect(imp.title == "YouTube Playlist", "Failed oEmbed should fall back to placeholder title")
        #expect(imp.channel == "Fallback Channel", "Failed oEmbed should fall back to first entry's uploader")
        // Fallback artwork: the first video's hqdefault.
        #expect(imp.artworkUrl == "https://i.ytimg.com/vi/track_oembed_1/hqdefault.jpg")
    }
}
final class YouTubeImportMetadataStub: StubURLProtocolBase, @unchecked Sendable {
    nonisolated(unsafe) private static var _rules: [StubRule] = []
    private static let _lock = NSLock()
    override class var rules: [StubRule] {
        get { _rules } set { _rules = newValue }
    }
    override class var lock: NSLock { _lock }
}
