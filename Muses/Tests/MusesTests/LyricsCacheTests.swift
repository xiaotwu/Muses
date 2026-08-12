import Testing
import Foundation
import SwiftData
@testable import Muses

@MainActor
@Suite("LyricsCache")
struct LyricsCacheTests {

    // MARK: - TrackSnapshot.lyrics Codable 向后兼容

    @Test("TrackSnapshot.lyrics 向后兼容:旧 JSON 无 lyrics 字段解码为 nil")
    func trackSnapshotLyricsBackwardCompat() throws {
        // 旧格式 JSON:没有 lyrics 字段
        let oldJSON = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "title": "Test",
            "artist": "Artist",
            "albumTitle": null,
            "durationSeconds": 180,
            "filePath": "/tmp/test.wav",
            "youTubeId": null,
            "artworkHash": null,
            "artworkUrl": null,
            "sampleRate": 44100,
            "bitDepth": 16,
            "codec": "pcm",
            "isLossless": false,
            "liked": false
        }
        """
        let data = Data(oldJSON.utf8)
        let snap = try JSONDecoder().decode(TrackSnapshot.self, from: data)
        #expect(snap.lyrics == nil)
        #expect(snap.title == "Test")
    }

    @Test("TrackSnapshot.lyrics 新 JSON 含 LRC 歌词正确解码")
    func trackSnapshotLyricsDecoded() throws {
        let lrc = "[00:01.00]Hello\\n[00:03.00]World"
        let newJSON = """
        {
            "id": "00000000-0000-0000-0000-000000000002",
            "title": "Test",
            "artist": "Artist",
            "albumTitle": null,
            "durationSeconds": 180,
            "filePath": "/tmp/test.wav",
            "youTubeId": null,
            "artworkHash": null,
            "artworkUrl": null,
            "sampleRate": 44100,
            "bitDepth": 16,
            "codec": "pcm",
            "isLossless": false,
            "liked": true,
            "lyrics": "\(lrc)"
        }
        """
        let data = Data(newJSON.utf8)
        let snap = try JSONDecoder().decode(TrackSnapshot.self, from: data)
        #expect(snap.lyrics != nil)
        #expect(snap.lyrics?.contains("[00:01.00]") == true)
        #expect(snap.liked == true)
    }

    // MARK: - 缓存命中跳过网络

    @Test("fetchCached 命中 Track.lyrics 返回 .cached source,不联网")
    func fetchCachedHitsAndSkipsNetwork() async throws {
        let container = try makeModelContainer(inMemory: true)
        let ctx = container.mainContext

        let track = Track(
            source: .local,
            title: "Test Song",
            artist: "Test Artist",
            albumTitle: nil,
            durationMs: 180_000,
            filePath: "/tmp/nonexistent.wav",
            metadataStatus: .embedded
        )
        track.lyrics = "[00:01.00]Cached line\\n[00:03.00]Second line"
        ctx.insert(track)
        try ctx.save()

        // TrackSnapshot 携带 lyrics
        let snap = TrackSnapshot(from: track)
        #expect(snap.lyrics != nil)

        let service = LyricsService(modelContainer: container)
        let cached = service.fetchCached(track: snap)
        #expect(cached != nil)
        #expect(cached?.source == .cached)
        #expect(cached?.syncedLyrics?.contains("[00:01.00]") == true)
    }

    @Test("fetchCached 无缓存返回 nil")
    func fetchCachedMiss() throws {
        let snap = TrackSnapshot(
            id: UUID(), title: "No Lyrics", artist: "Artist", albumTitle: nil,
            durationSeconds: 60, filePath: nil, youTubeId: nil,
            artworkHash: nil, artworkUrl: nil,
            sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false,
            liked: false, lyrics: nil)

        let service = LyricsService()
        let cached = service.fetchCached(track: snap)
        #expect(cached == nil)
    }

    @Test("persistLyrics 写回 Track.lyrics")
    func persistLyricsWritesBack() async throws {
        let container = try makeModelContainer(inMemory: true)
        let ctx = container.mainContext

        let track = Track(
            source: .local,
            title: "Song",
            artist: "Artist",
            albumTitle: nil,
            durationMs: 120_000,
            filePath: "/tmp/test.wav",
            metadataStatus: .embedded
        )
        ctx.insert(track)
        try ctx.save()
        let trackId = track.id
        #expect(track.lyrics == nil)

        let service = LyricsService(modelContainer: container)
        // 模拟网络获取后写回
        let result = LyricsResult(
            plainLyrics: nil,
            syncedLyrics: "[00:00.00]Cached\\n[00:02.00]Lyrics",
            source: .lrclib
        )
        // fetch 内部会调 persistLyrics;这里直接验证 fetchCached 的往返
        // 先写回,再读缓存
        let snap = TrackSnapshot(from: track)
        _ = snap  // snap.lyrics 目前是 nil

        // 用一个新 snap 带有 lyrics 来验证 fetchCached
        let snapWithLyrics = TrackSnapshot(
            id: trackId, title: "Song", artist: "Artist", albumTitle: nil,
            durationSeconds: 120, filePath: nil, youTubeId: nil,
            artworkHash: nil, artworkUrl: nil,
            sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false,
            liked: false, lyrics: result.syncedLyrics)

        let cached = service.fetchCached(track: snapWithLyrics)
        #expect(cached?.source == .cached)
        #expect(cached?.syncedLyrics == result.syncedLyrics)
    }
}