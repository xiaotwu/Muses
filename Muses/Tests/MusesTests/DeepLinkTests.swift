import Testing
import Foundation
import SwiftData
@testable import Muses

/// Deep link 端到端测试:`muses://play?trackId=<id>` → 解析 → 持久层取 Track
/// → 转 TrackSnapshot → PlaybackService.playTrack 路由到引擎。
@MainActor
@Suite("DeepLink")
struct DeepLinkTests {

    /// 构造 in-memory 容器并插入一首本地 Track,返回 (container, track)。
    private func makeContainerWithTrack() throws -> (ModelContainer, Track) {
        let container = try makeModelContainer(inMemory: true)
        let context = container.mainContext
        let track = Track(source: .local, title: "Deep", artist: "Linker",
                          durationMs: 180_000, filePath: "/tmp/deep.wav")
        context.insert(track)
        try context.save()
        return (container, track)
    }

    @Test("muses://play?trackId 解析并播放对应 Track")
    func deepLinkParsesAndPlays() async throws {
        let (container, track) = try makeContainerWithTrack()
        let url = URL(string: "muses://play?trackId=\(track.id.uuidString)")!

        // 1. SpotlightIndexer 解析 trackId。
        let parsedId = try #require(SpotlightIndexer.trackId(from: url))
        #expect(parsedId == track.id)

        // 2. 持久层按 id 取 Track(MusesApp.onOpenURL 同款逻辑)。
        let context = container.mainContext
        let descriptor = FetchDescriptor<Track>()
        let fetched = (try context.fetch(descriptor)).first { $0.id == parsedId }
        let resolved = try #require(fetched)
        #expect(resolved.title == "Deep")

        // 3. 转 snapshot 喂给 PlaybackService,验证引擎收到 load。
        let localMock = RecordingEngine()
        let svc = PlaybackService(localEngine: localMock,
                                  youtubeEngine: RecordingEngine(),
                                  queue: QueueService())
        let snap = TrackSnapshot(from: resolved)
        svc.playTrack(snap, context: [snap], from: .songs)
        try await Task.sleep(for: .milliseconds(120))
        #expect(localMock.loadCallCount == 1)
        #expect(localMock.lastLoadedTrack?.title == "Deep")
    }

    @Test("非 muses scheme 或缺 trackId 返回 nil")
    func invalidDeepLinkReturnsNil() {
        #expect(SpotlightIndexer.trackId(from: URL(string: "https://example.com")!) == nil)
        #expect(SpotlightIndexer.trackId(from: URL(string: "muses://play")!) == nil)
        #expect(SpotlightIndexer.trackId(from: URL(string: "muses://play?trackId=not-a-uuid")!) == nil)
    }
}