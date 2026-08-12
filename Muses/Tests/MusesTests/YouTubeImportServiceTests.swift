import Testing
import Foundation
import SwiftData
@testable import Muses

@MainActor
@Suite("YouTubeImportService")
struct YouTubeImportServiceTests {

    // MARK: - 1. importPlaylist 创建 import + items + tracks

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

        // 返回非空 UUID。
        #expect(importId != UUID())

        // 验证 bridge 被调用一次。
        #expect(bridge.fetchCallCount == 1)

        // 新 context 验证持久化。
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

        // Track:source .youtube,youTubeId 正确,artworkUrl 指向缩略图。
        let tracks = try verifyCtx.fetch(FetchDescriptor<Track>())
        #expect(tracks.count == 2)
        let v1Track = try #require(tracks.first { $0.youTubeId == "v1" })
        #expect(v1Track.source == .youtube)
        #expect(v1Track.title == "Song A")
        #expect(v1Track.artworkUrl == "https://i.ytimg.com/vi/v1/hqdefault.jpg")
        let v2Track = try #require(tracks.first { $0.youTubeId == "v2" })
        #expect(v2Track.source == .youtube)
        #expect(v2Track.artworkUrl == "https://i.ytimg.com/vi/v2/hqdefault.jpg")

        // import.artworkUrl 指向首条视频缩略图。
        #expect(imp.artworkUrl == "https://i.ytimg.com/vi/v1/hqdefault.jpg")

        // item.track 已关联。
        #expect(sortedItems[0].track?.youTubeId == "v1")
        #expect(sortedItems[1].track?.youTubeId == "v2")
    }

    // MARK: - 2. resync 合并条目(新增/移除/更新)

    @Test("resync 合并新增并移除消失的条目")
    func resyncMergesEntries() async throws {
        let container = try makeModelContainer(inMemory: true)
        let bridge = MockImportBridge()
        bridge.entries = [
            YTDlpBridge.YTDlpPlaylistEntry(
                id: "v1", title: "Song A", uploader: "Chan", duration: 201.5),
            YTDlpBridge.YTDlpPlaylistEntry(
                id: "v2", title: "Song B", uploader: "Chan", duration: 180.0),
        ]

        let service = makeService(bridge: bridge, container: container)

        // 先导入 2 条。
        let importId = try await service.importPlaylist(
            url: "https://www.youtube.com/playlist?list=PLresync")
        // 记录 v2 的 Track id,验证 resync 后 Track 仍存在。
        let preCtx = ModelContext(container)
        let preItems = try preCtx.fetch(FetchDescriptor<YouTubeImport>())
        let v2ItemId = try #require(
            (preItems.first?.items ?? []).first { $0.youTubeId == "v2" }?.id)
        let v2TrackId = try #require(
            (preItems.first?.items ?? []).first { $0.youTubeId == "v2" }?.track?.id)

        // 改变 mock 条目:保留 v1,移除 v2,新增 v3。
        bridge.entries = [
            YTDlpBridge.YTDlpPlaylistEntry(
                id: "v1", title: "Song A (Remaster)", uploader: "Chan2", duration: 205.0),
            YTDlpBridge.YTDlpPlaylistEntry(
                id: "v3", title: "Song C", uploader: "Chan", duration: 240.0),
        ]

        let ok = try await service.resync(importId: importId)
        #expect(ok == true)
        #expect(bridge.fetchCallCount == 2)

        // 验证:items = 2(v1 + v3),v2 item 被删,但 v2 Track 仍在。
        let verifyCtx = ModelContext(container)
        let imports = try verifyCtx.fetch(FetchDescriptor<YouTubeImport>())
        let imp = try #require(imports.first)
        let items = imp.items ?? []
        #expect(items.count == 2)
        let youTubeIds = Set(items.map { $0.youTubeId })
        #expect(youTubeIds == ["v1", "v3"])

        // v1 条目字段被更新。
        let v1Item = try #require(items.first { $0.youTubeId == "v1" })
        #expect(v1Item.title == "Song A (Remaster)")
        #expect(v1Item.artist == "Chan2")
        #expect(v1Item.durationMs == 205000)
        #expect(v1Item.track?.title == "Song A (Remaster)")

        // v2 item 已删除。
        let allItems = try verifyCtx.fetch(FetchDescriptor<YouTubeImportItem>())
        #expect(allItems.contains { $0.id == v2ItemId } == false)

        // v2 Track 仍在(nullify)。
        let allTracks = try verifyCtx.fetch(FetchDescriptor<Track>())
        #expect(allTracks.contains { $0.id == v2TrackId } == true)

        // v3 是新增 Track。
        let v3Track = try #require(allTracks.first { $0.youTubeId == "v3" })
        #expect(v3Track.source == .youtube)
    }

    // MARK: - 3. deleteImport 默认保留 Track

    @Test("deleteImport 默认保留 Track")
    func deleteImportKeepsTracksByDefault() async throws {
        let container = try makeModelContainer(inMemory: true)
        let bridge = MockImportBridge()
        bridge.entries = [
            YTDlpBridge.YTDlpPlaylistEntry(
                id: "d1", title: "Del A", uploader: "Chan", duration: 100.0),
            YTDlpBridge.YTDlpPlaylistEntry(
                id: "d2", title: "Del B", uploader: "Chan", duration: 120.0),
        ]

        let service = makeService(bridge: bridge, container: container)
        let importId = try await service.importPlaylist(
            url: "https://www.youtube.com/playlist?list=PLdelete")

        service.deleteImport(importId: importId) // deleteTracks 默认 false

        let verifyCtx = ModelContext(container)
        let imports = try verifyCtx.fetch(FetchDescriptor<YouTubeImport>())
        #expect(imports.isEmpty)
        let items = try verifyCtx.fetch(FetchDescriptor<YouTubeImportItem>())
        #expect(items.isEmpty)
        // Track 保留。
        let tracks = try verifyCtx.fetch(FetchDescriptor<Track>())
        #expect(tracks.count == 2)
        let ytIds = Set(tracks.compactMap { $0.youTubeId })
        #expect(ytIds == ["d1", "d2"])
    }

    // MARK: - 3b. deleteImport deleteTracks=true 一并删除 Track

    @Test("deleteImport(deleteTracks: true) 删除关联 Track")
    func deleteImportWithTracks() async throws {
        let container = try makeModelContainer(inMemory: true)
        let bridge = MockImportBridge()
        bridge.entries = [
            YTDlpBridge.YTDlpPlaylistEntry(
                id: "dt1", title: "T", uploader: "C", duration: 100.0),
        ]

        let service = makeService(bridge: bridge, container: container)
        let importId = try await service.importPlaylist(
            url: "https://www.youtube.com/playlist?list=PLdelT")

        service.deleteImport(importId: importId, deleteTracks: true)

        let verifyCtx = ModelContext(container)
        let imports = try verifyCtx.fetch(FetchDescriptor<YouTubeImport>())
        #expect(imports.isEmpty)
        let items = try verifyCtx.fetch(FetchDescriptor<YouTubeImportItem>())
        #expect(items.isEmpty)
        let tracks = try verifyCtx.fetch(FetchDescriptor<Track>())
        #expect(tracks.isEmpty)
    }

    // MARK: - 4. localAddition 添加与移除

    @Test("localAddition 添加和移除")
    func localAdditionAddAndRemove() async throws {
        let container = try makeModelContainer(inMemory: true)
        let bridge = MockImportBridge()
        bridge.entries = [
            YTDlpBridge.YTDlpPlaylistEntry(
                id: "la1", title: "Song", uploader: "Chan", duration: 100.0),
        ]

        let service = makeService(bridge: bridge, container: container)
        let importId = try await service.importPlaylist(
            url: "https://www.youtube.com/playlist?list=PLla")

        // 在容器里新建一个本地 Track。
        let setupCtx = ModelContext(container)
        let localTrack = Track(
            source: .local, title: "Local Song", artist: "Me",
            filePath: "/tmp/local.flac")
        setupCtx.insert(localTrack)
        try setupCtx.save()
        let localTrackId = localTrack.id

        // 添加。
        let added = service.addLocalAddition(importId: importId, trackId: localTrackId)
        #expect(added == true)

        let verifyCtx1 = ModelContext(container)
        let imp1 = try #require(verifyCtx1.fetch(FetchDescriptor<YouTubeImport>()).first)
        #expect(imp1.localAdditions?.count == 1)
        #expect(imp1.localAdditions?[0].id == localTrackId)

        // 重复添加应去重(返回 true,数量不变)。
        let addedAgain = service.addLocalAddition(importId: importId, trackId: localTrackId)
        #expect(addedAgain == true)
        let verifyCtx1b = ModelContext(container)
        let imp1b = try #require(verifyCtx1b.fetch(FetchDescriptor<YouTubeImport>()).first)
        #expect(imp1b.localAdditions?.count == 1)

        // 移除。
        let removed = service.removeLocalAddition(importId: importId, trackId: localTrackId)
        #expect(removed == true)
        let verifyCtx2 = ModelContext(container)
        let imp2 = try #require(verifyCtx2.fetch(FetchDescriptor<YouTubeImport>()).first)
        #expect(imp2.localAdditions?.count == 0)

        // 本地 Track 仍保留(nullify)。
        let tracks = try verifyCtx2.fetch(FetchDescriptor<Track>())
        #expect(tracks.contains { $0.id == localTrackId } == true)
    }

    // MARK: - 边界:空歌单 / 无效 URL

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

    @Test("resync 未找到 import 返回 false")
    func resyncNotFoundReturnsFalse() async throws {
        let container = try makeModelContainer(inMemory: true)
        let bridge = MockImportBridge()
        let service = makeService(bridge: bridge, container: container)

        let ok = try await service.resync(importId: UUID())
        #expect(ok == false)
    }

    // MARK: - 工厂

    /// 构造一个使用临时 ArtworkCache + 短超时 ephemeral session(无 stub 规则时
    /// 网络请求会快速失败,因此 artwork 下载不阻塞,也不会写入磁盘)的服务。
    private func makeService(bridge: MockImportBridge,
                            container: ModelContainer) -> YouTubeImportService {
        StubURLProtocol.reset()
        let stub = StubURLProtocol()
        // 对所有请求返回 404 —— 这样 artwork 下载会非 2xx 失败,不写入缓存。
        stub.respond(forHostContaining: "") { _ in
            StubResponse(statusCode: 404, body: Data())
        }
        let session = URLSession(configuration: StubURLProtocol.makeConfig(stub))
        let artworkCache = ArtworkCache(
            directory: FileManager.default.temporaryDirectory
                .appending(path: "muses-yt-import-\(UUID().uuidString)"))
        return YouTubeImportService(
            bridge: bridge,
            modelContainer: container,
            artworkCache: artworkCache,
            session: session
        )
    }
}

// MARK: - Mock bridge

@MainActor
final class MockImportBridge: YTDlpBridgeProtocol {
    var entries: [YTDlpBridge.YTDlpPlaylistEntry] = []
    var fetchCallCount = 0

    func resolveStreamURL(videoId: String, quality: String, timeout: TimeInterval) async throws -> URL {
        URL(string: "https://example.com/a")!
    }

    func fetchPlaylist(url: String, timeout: TimeInterval) async throws -> [YTDlpBridge.YTDlpPlaylistEntry] {
        fetchCallCount += 1
        return entries
    }

    func version() async -> String? { "mock" }
}