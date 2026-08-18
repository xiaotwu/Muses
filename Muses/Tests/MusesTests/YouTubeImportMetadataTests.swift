import Testing
import Foundation
import SwiftData
@testable import Muses

/// YouTube oEmbed 歌单元数据集成测试。
/// 验证 importPlaylist / resync 通过 oEmbed API 获取真实标题/频道/封面,
/// 以及 oEmbed 失败时回退到占位值。
@MainActor
@Suite("YouTubeImportMetadata", .serialized)
struct YouTubeImportMetadataTests {

    // MARK: - oEmbed 成功

    @Test("importPlaylist oEmbed 成功 → 真实标题/频道/封面")
    func oEmbedSuccessPopulatesMetadata() async throws {
        let container = try makeModelContainer(inMemory: true)
        let bridge = MockImportBridge()
        bridge.entries = [
            YTDlpBridge.YTDlpPlaylistEntry(
                id: "v1", title: "Song A", uploader: "Some Channel", duration: 200),
        ]

        YouTubeImportMetadataStub.reset()
        let stub = YouTubeImportMetadataStub()
        // oEmbed 请求:host 含 "youtube.com" 且 path 含 "/oembed"
        stub.respond(forHostContaining: "youtube.com") { req in
            if req.url?.path.contains("/oembed") == true {
                let json = """
                {"title":"My Awesome Playlist","author_name":"Awesome Creator","thumbnail_url":"https://i.ytimg.com/vi/playlist/thumb.jpg"}
                """.data(using: .utf8)!
                return StubResponse(statusCode: 200, body: json,
                                    headers: ["Content-Type": "application/json"])
            }
            // 其他请求(artwork 下载等)→ 404,不阻塞
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
        #expect(imp.title == "My Awesome Playlist", "oEmbed 标题应填入")
        #expect(imp.channel == "Awesome Creator", "oEmbed 频道应填入")
        #expect(imp.artworkUrl == "https://i.ytimg.com/vi/playlist/thumb.jpg",
                "oEmbed 封面 URL 应填入")
    }

    // MARK: - oEmbed 失败回退

    @Test("importPlaylist oEmbed 404 → 回退占位标题/频道")
    func oEmbedFailureFallsBack() async throws {
        let container = try makeModelContainer(inMemory: true)
        let bridge = MockImportBridge()
        bridge.entries = [
            YTDlpBridge.YTDlpPlaylistEntry(
                id: "v1", title: "Song A", uploader: "Fallback Channel", duration: 200),
        ]

        YouTubeImportMetadataStub.reset()
        let stub = YouTubeImportMetadataStub()
        // 所有请求返回 404(oEmbed + artwork 都失败)
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
        // 回退:标题占位,频道用首条 entry uploader。
        #expect(imp.title == "YouTube Playlist", "oEmbed 失败应回退占位标题")
        #expect(imp.channel == "Fallback Channel", "oEmbed 失败应回退首条 uploader")
        // 回退封面:首条视频 hqdefault。
        #expect(imp.artworkUrl == "https://i.ytimg.com/vi/v1/hqdefault.jpg")
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
