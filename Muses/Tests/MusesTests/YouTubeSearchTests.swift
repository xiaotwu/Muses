import Testing
import Foundation
import SwiftData
@testable import Muses

/// YouTube 搜索服务测试。
@MainActor
@Suite("YouTubeSearch")
struct YouTubeSearchTests {

    @Test("search 返回 bridge 结果")
    func searchReturnsResults() async throws {
        let container = try makeModelContainer(inMemory: true)
        let bridge = MockImportBridge()
        bridge.searchResults = [
            YTDlpBridge.YTDlpPlaylistEntry(id: "s1", title: "Result A", uploader: "Chan A", duration: 180),
            YTDlpBridge.YTDlpPlaylistEntry(id: "s2", title: "Result B", uploader: "Chan B", duration: 240),
        ]
        let service = YouTubeSearchService(bridge: bridge, modelContainer: container)

        let results = try await service.search(query: "test query")
        #expect(results.count == 2)
        #expect(results[0].id == "s1")
        #expect(bridge.searchCallCount == 1)
    }

    @Test("search 空查询返回空数组(不调 bridge)")
    func searchEmptyQuerySkipsBridge() async throws {
        let container = try makeModelContainer(inMemory: true)
        let bridge = MockImportBridge()
        let service = YouTubeSearchService(bridge: bridge, modelContainer: container)

        let results = try await service.search(query: "   ")
        #expect(results.isEmpty)
        #expect(bridge.searchCallCount == 0)
    }

    @Test("importAsTrack 创建 .youtube Track + 去重")
    func importAsTrackCreatesAndDeduplicates() async throws {
        let container = try makeModelContainer(inMemory: true)
        let bridge = MockImportBridge()
        let service = YouTubeSearchService(bridge: bridge, modelContainer: container)

        let entry = YTDlpBridge.YTDlpPlaylistEntry(id: "dup1", title: "Dup Song", uploader: "Dup Artist", duration: 200)

        // 首次导入 → 创建 Track
        let snap1 = try await service.importAsTrack(entry: entry)
        #expect(snap1.youTubeId == "dup1")
        #expect(snap1.title == "Dup Song")

        // 验证持久化
        let ctx = ModelContext(container)
        let tracks = try ctx.fetch(FetchDescriptor<Track>())
        #expect(tracks.count == 1)
        #expect(tracks.first?.youTubeId == "dup1")

        // 再次导入同一 entry → 返回既有,不新建
        let snap2 = try await service.importAsTrack(entry: entry)
        #expect(snap2.id == snap1.id)
        let tracks2 = try ctx.fetch(FetchDescriptor<Track>())
        #expect(tracks2.count == 1, "去重:不应创建第二个 Track")
    }
}
