import Testing
import Foundation
import SwiftData
@testable import Muses

/// 阶段 3 端到端冒烟:YouTube 导入 → 双引擎调度 → 歌词(LRCLIB)→ Spotlight deep link
/// → Sparkle appcast 解析。把跨层的 Phase 3 能力串成一条路径,确保各任务实现彼此咬合。
@MainActor
@Suite("Phase3Smoke")
struct Phase3SmokeTests {

    @Test("Phase 3 端到端:导入 → 播放调度 → 歌词 → deep link → appcast")
    func endToEnd() async throws {
        let container = try makeModelContainer(inMemory: true)

        // ── 1. YouTube 导入(mock bridge)──────────────────────────────
        let bridge = MockImportBridge()
        bridge.entries = [
            YTDlpBridge.YTDlpPlaylistEntry(
                id: "smoke1", title: "Smoke Song", uploader: "Smoke Chan", duration: 200.0),
        ]
        // catch-all 404:artwork 下载快速失败,不写缓存(MockImportBridge 已隔离 yt-dlp)。
        StubURLProtocol.reset()
        let artStub = StubURLProtocol()
        artStub.respond(forHostContaining: "") { _ in
            StubResponse(statusCode: 404, body: Data())
        }
        let artworkCache = ArtworkCache(
            directory: FileManager.default.temporaryDirectory
                .appending(path: "muses-phase3-smoke-\(UUID().uuidString)"))
        let session = URLSession(configuration: StubURLProtocol.makeConfig(artStub))
        let importService = YouTubeImportService(
            bridge: bridge, modelContainer: container,
            artworkCache: artworkCache, session: session
        )

        let importId = try await importService.importPlaylist(
            url: "https://www.youtube.com/playlist?list=PLsmoke")
        #expect(importId != UUID())
        #expect(bridge.fetchCallCount == 1)

        // 验证 .youtube Track 被懒创建。
        let ctx = container.mainContext
        let tracks = try ctx.fetch(FetchDescriptor<Track>())
        #expect(tracks.count == 1)
        let ytTrack = try #require(tracks.first)
        #expect(ytTrack.source == .youtube)
        #expect(ytTrack.youTubeId == "smoke1")

        // ── 2. 双引擎调度:.youtube Track 路由到 youtubeEngine ──────────
        let localMock = RecordingEngine()
        let ytMock = RecordingEngine()
        let playback = PlaybackService(
            localEngine: localMock, youtubeEngine: ytMock, queue: QueueService())
        let snap = TrackSnapshot(from: ytTrack)
        playback.playTrack(snap, context: [snap], from: .import)
        try await Task.sleep(for: .milliseconds(120))
        #expect(ytMock.loadCallCount == 1)
        #expect(ytMock.lastLoadedTrack?.youTubeId == "smoke1")
        #expect(localMock.loadCallCount == 0)

        // ── 3. 歌词:LRCLIB stub 返回同步歌词 ──────────────────────────
        StubURLProtocol.reset()
        let lrcStub = StubURLProtocol()
        lrcStub.respond(forHostEndingWith: "lrclib.net") { _ in
            StubResponse(
                statusCode: 200,
                body: Data(#"{"plainLyrics":"words","syncedLyrics":"[00:01.00] smoke line"}"#.utf8))
        }
        let lrcSession = URLSession(configuration: StubURLProtocol.makeConfig(lrcStub))
        let lyrics = LyricsService(session: lrcSession)
        let lyricsTrack = TrackSnapshot(
            id: UUID(), title: "Smoke Song", artist: "Smoke Chan", albumTitle: nil,
            durationSeconds: 200, filePath: nil, youTubeId: "smoke1",
            artworkHash: nil, artworkUrl: nil,
            sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false)
        let originalPref = UserDefaults.standard.string(forKey: PrefKey.lyricsSource)
        UserDefaults.standard.set("lrclib", forKey: PrefKey.lyricsSource)
        defer {
            if let originalPref {
                UserDefaults.standard.set(originalPref, forKey: PrefKey.lyricsSource)
            } else {
                UserDefaults.standard.removeObject(forKey: PrefKey.lyricsSource)
            }
        }
        let lrcResult = try #require(await lyrics.fetch(track: lyricsTrack))
        #expect(lrcResult.source == LyricsSource.lrclib)
        #expect(lrcResult.syncedLyrics?.contains("[00:01.00] smoke line") == true)

        // ── 4. Spotlight deep link:本地 Track 经 muses://play 唤起播放 ─
        let localTrack = Track(source: .local, title: "Local Smoke", artist: "Linker",
                               durationMs: 120_000, filePath: "/tmp/local.wav")
        ctx.insert(localTrack)
        try ctx.save()
        let dlURL = URL(string: "muses://play?trackId=\(localTrack.id.uuidString)")!
        let parsed = try #require(SpotlightIndexer.trackId(from: dlURL))
        #expect(parsed == localTrack.id)
        let fetched = (try ctx.fetch(FetchDescriptor<Track>())).first { $0.id == parsed }
        let resolvedLocal = try #require(fetched)
        let localSnap = TrackSnapshot(from: resolvedLocal)
        playback.playTrack(localSnap, context: [localSnap], from: .songs)
        try await Task.sleep(for: .milliseconds(120))
        #expect(localMock.loadCallCount == 1)
        #expect(localMock.lastLoadedTrack?.title == "Local Smoke")

        // ── 5. Sparkle appcast 模板可解析 ───────────────────────────────
        let appcastURL = try #require(MusesResources.appcastURL)
        let parser = XMLParser(data: try Data(contentsOf: appcastURL))
        #expect(parser.parse(), "appcast.xml 解析失败")
    }
}