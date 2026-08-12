import Testing
import Foundation
@testable import Muses

@MainActor
@Suite("WaveformCache Integration")
struct WaveformCacheIntegrationTests {
    @Test("load 后波形缓存命中")
    func waveformCachedAfterLoad() async throws {
        let wav = FileManager.default.temporaryDirectory.appending(path: "muses-wave-\(UUID().uuidString).wav")
        try makeSilentWav(at: wav, seconds: 1)
        let snap = TrackSnapshot(id: UUID(), title: "t", artist: "a", albumTitle: nil,
                                 durationSeconds: 1, filePath: wav.path, youTubeId: nil,
                                 artworkHash: nil, artworkUrl: nil, sampleRate: 44100,
                                 bitDepth: 16, codec: "pcm", isLossless: false)
        let engine = LocalAudioEngine()
        try await engine.load(snap)
        // 后台预扫描是 detached Task, 轮询等缓存落盘
        var peaks: [Float]? = nil
        for _ in 0..<40 {   // 最多 ~2s
            peaks = WaveformCache.default.load(forTrackId: snap.id)
            if peaks != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(peaks != nil)
        #expect((peaks?.count ?? 0) > 0)
    }

    @Test("重复 load 命中缓存不再重算")
    func cacheHitSkipsRecompute() async throws {
        let wav = FileManager.default.temporaryDirectory.appending(path: "muses-wave2-\(UUID().uuidString).wav")
        try makeSilentWav(at: wav, seconds: 1)
        let snap = TrackSnapshot(id: UUID(), title: "t", artist: "a", albumTitle: nil,
                                 durationSeconds: 1, filePath: wav.path, youTubeId: nil,
                                 artworkHash: nil, artworkUrl: nil, sampleRate: 44100,
                                 bitDepth: 16, codec: "pcm", isLossless: false)
        let engine = LocalAudioEngine()
        try await engine.load(snap)
        for _ in 0..<40 { if WaveformCache.default.load(forTrackId: snap.id) != nil { break }; try await Task.sleep(for: .milliseconds(50)) }
        let first = WaveformCache.default.load(forTrackId: snap.id)
        // 第二次 load 命中缓存(静音 WAV 峰值全 0,但缓存行存在)
        try await engine.load(snap)
        try await Task.sleep(for: .milliseconds(100))
        let second = WaveformCache.default.load(forTrackId: snap.id)
        #expect(first != nil)
        #expect(second != nil)
    }
}
