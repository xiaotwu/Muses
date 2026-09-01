import Testing
import Foundation
@testable import Muses

@MainActor
@Suite("YouTubeStreamEngine", .serialized)
struct YouTubeStreamEngineTests {

    // MARK: - 1. A successful load sets state.source = .youtube

    @Test("load 成功设置 state.source = .youtube 且 duration > 0")
    func loadSuccessSetsSource() async throws {
        let wav = try makeWAVFile()
        let bridge = MockYTDlpBridge()
        bridge.streamURL = wav
        let engine = YouTubeStreamEngine(bridge: bridge, cache: StreamURLCache(defaultTTL: 3600))
        let snap = TrackSnapshot(
            id: UUID(), title: "t", artist: "a", albumTitle: nil,
            durationSeconds: 1, youTubeId: "vid1",
            artworkUrl: nil,
            sampleRate: 44100, bitDepth: 16, codec: "aac", isLossless: false)
        try await engine.load(snap)
        #expect(engine.state.duration > 0)
        #expect(engine.state.error == nil)
        #expect(engine.state.buffering == false)
        #expect(!engine.isInFallbackMode)
    }

    // MARK: - 2. A failed load sets state.error = .sourceUnavailable

    @Test("load 失败设置 state.error = .sourceUnavailable")
    func loadFailureSetsError() async throws {
        let bridge = MockYTDlpBridge()
        bridge.shouldFail = true
        let engine = YouTubeStreamEngine(bridge: bridge, cache: StreamURLCache(defaultTTL: 3600))
        let snap = TrackSnapshot(
            id: UUID(), title: "t", artist: "a", albumTitle: nil,
            durationSeconds: 1, youTubeId: "vid2",
            artworkUrl: nil,
            sampleRate: 44100, bitDepth: 16, codec: "aac", isLossless: false)
        do {
            try await engine.load(snap)
            Issue.record("应抛出 PlayerError.sourceUnavailable")
        } catch {
            #expect(engine.state.error == .sourceUnavailable)
        }
        #expect(engine.state.buffering == false)
    }

    // MARK: - 3. buffering resets to zero after load success/failure (covered by 1/2; asserted separately here)

    @Test("load 成功后 buffering == false")
    func bufferingFalseAfterSuccess() async throws {
        let wav = try makeWAVFile()
        let bridge = MockYTDlpBridge()
        bridge.streamURL = wav
        let engine = YouTubeStreamEngine(bridge: bridge, cache: StreamURLCache(defaultTTL: 3600))
        let snap = TrackSnapshot(
            id: UUID(), title: "t", artist: "a", albumTitle: nil,
            durationSeconds: 1, youTubeId: "vid3",
            artworkUrl: nil,
            sampleRate: 44100, bitDepth: 16, codec: "aac", isLossless: false)
        try await engine.load(snap)
        #expect(engine.state.buffering == false)
    }

    // MARK: - 4. AVPlayer fallback path

    @Test("下载失败时降级到 AVPlayer 且不报错")
    func avPlayerFallback() async throws {
        let bridge = MockYTDlpBridge()
        // Use a .test TLD so DNS resolution fails fast, combined with a short timeout
        bridge.streamURL = URL(string: "https://invalid.example.test/audio.m4a")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1
        config.timeoutIntervalForResource = 2
        let session = URLSession(configuration: config)
        let engine = YouTubeStreamEngine(
            bridge: bridge, cache: StreamURLCache(defaultTTL: 3600), session: session)
        let snap = TrackSnapshot(
            id: UUID(), title: "t", artist: "a", albumTitle: nil,
            durationSeconds: 1, youTubeId: "vid4",
            artworkUrl: nil,
            sampleRate: 44100, bitDepth: 16, codec: "aac", isLossless: false)
        try await engine.load(snap)
        await engine.awaitHybridWorkForTests()
        #expect(engine.state.error == nil)
        #expect(engine.isInFallbackMode)
        #expect(engine.state.buffering == false)
    }

    // MARK: - 5. Two-node switching: load swaps activePlayer

    @Test("load 后 activePlayer 已初始化且 state 正确")
    func loadSwapsActivePlayer() async throws {
        let wav = try makeWAVFile()
        let bridge = MockYTDlpBridge()
        bridge.streamURL = wav
        let engine = YouTubeStreamEngine(bridge: bridge, cache: StreamURLCache(defaultTTL: 3600))
        let snap = TrackSnapshot(
            id: UUID(), title: "t", artist: "a", albumTitle: nil,
            durationSeconds: 1, youTubeId: "vid5",
            artworkUrl: nil,
            sampleRate: 44100, bitDepth: 16, codec: "aac", isLossless: false)
        try await engine.load(snap)
        // Initially activePlayer = playerA; load() schedules the file on the inactive node (playerB) and swaps
        #expect(engine._activeIsPlayerA == false)
        #expect(!engine.isInFallbackMode)
        #expect(!engine._isStreamingMode)
    }

    // MARK: - 6. Preloading: prepare downloads + decodes in the background into the prefetch slot

    @Test("prepare 预加载下一首文件且不改变当前 state")
    func preparePrefetchesFile() async throws {
        let wav = try makeWAVFile(seconds: 5)
        let bridge = MockYTDlpBridge()
        bridge.streamURL = wav
        let engine = YouTubeStreamEngine(bridge: bridge, cache: StreamURLCache(defaultTTL: 3600))
        let snapA = TrackSnapshot(
            id: UUID(), title: "Track A", artist: "a", albumTitle: nil,
            durationSeconds: 5, youTubeId: "vid6",
            artworkUrl: nil,
            sampleRate: 44100, bitDepth: 16, codec: "aac", isLossless: false)
        let snapB = TrackSnapshot(
            id: UUID(), title: "Track B", artist: "a", albumTitle: nil,
            durationSeconds: 5, youTubeId: "vid7",
            artworkUrl: nil,
            sampleRate: 44100, bitDepth: 16, codec: "aac", isLossless: false)

        try await engine.load(snapA)
        engine.play()

        // Before preload: no prefetch
        #expect(!engine._isPrefetched)

        await engine.prepare(snapB)

        // After preload: the prefetch is ready, but the currently playing track is still A
        #expect(engine._isPrefetched)
        #expect(engine.state.track?.title == "Track A")
        #expect(engine.state.isPlaying)
    }

    // MARK: - 7. playPrepared switches seamlessly to the preloaded track

    @Test("playPrepared 切换到预加载曲目并交换 activePlayer")
    func playPreparedSwapsPlayer() async throws {
        let wav = try makeWAVFile()
        let bridge = MockYTDlpBridge()
        bridge.streamURL = wav
        let engine = YouTubeStreamEngine(bridge: bridge, cache: StreamURLCache(defaultTTL: 3600))
        let snapA = TrackSnapshot(
            id: UUID(), title: "Track A", artist: "a", albumTitle: nil,
            durationSeconds: 1, youTubeId: "vid8",
            artworkUrl: nil,
            sampleRate: 44100, bitDepth: 16, codec: "aac", isLossless: false)
        let snapB = TrackSnapshot(
            id: UUID(), title: "Track B", artist: "a", albumTitle: nil,
            durationSeconds: 1, youTubeId: "vid9",
            artworkUrl: nil,
            sampleRate: 44100, bitDepth: 16, codec: "aac", isLossless: false)

        try await engine.load(snapA)
        engine.play()
        let activeBefore = engine._activeIsPlayerA

        await engine.prepare(snapB)
        let ok = engine.playPrepared()
        #expect(ok)

        // state switched to Track B
        #expect(engine.state.track?.title == "Track B")
        #expect(engine.state.isPlaying)
        #expect(engine.state.duration > 0)

        // activePlayer swapped
        #expect(engine._activeIsPlayerA != activeBefore)

        // Preload cleared
        #expect(!engine._isPrefetched)

        // Without a preload, playPrepared returns false
        let ok2 = engine.playPrepared()
        #expect(!ok2)
    }

    @Test("new load silences the old node and pause survives hybrid handoff")
    func pauseSurvivesHybridHandoff() async throws {
        let wav = try makeWAVFile(seconds: 3)
        let bridge = MockYTDlpBridge()
        let firstVideoId = "first-\(UUID().uuidString)"
        let secondVideoId = "second-\(UUID().uuidString)"
        let quality = UserDefaults.standard.string(forKey: PrefKey.ytAudioQuality) ?? "bestaudio"
        defer {
            MediaFileCache.remove(videoId: firstVideoId, quality: quality)
            MediaFileCache.remove(videoId: secondVideoId, quality: quality)
        }
        let engine = YouTubeStreamEngine(
            bridge: bridge,
            cache: StreamURLCache(defaultTTL: 3600),
            downloadOverride: { source, destination in
                if !source.isFileURL {
                    try? await Task.sleep(for: .milliseconds(80))
                }
                guard !Task.isCancelled else { return false }
                do {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.copyItem(at: wav, to: destination)
                    return true
                } catch {
                    return false
                }
            }
        )
        let first = TrackSnapshot(
            id: UUID(), title: "Decoded", artist: "a", albumTitle: nil,
            durationSeconds: 3, youTubeId: firstVideoId,
            artworkUrl: nil,
            sampleRate: 44_100, bitDepth: 16, codec: "aac", isLossless: false)
        let second = TrackSnapshot(
            id: UUID(), title: "Streaming", artist: "a", albumTitle: nil,
            durationSeconds: 3, youTubeId: secondVideoId,
            artworkUrl: nil,
            sampleRate: 44_100, bitDepth: 16, codec: "aac", isLossless: false)

        bridge.streamURL = wav
        try await engine.load(first)
        engine.play()
        #expect(engine.state.isPlaying)

        bridge.streamURL = URL(string: "https://stream.invalid/second.wav")!
        try await engine.load(second)
        // Loading a new backend must silence the prior decoded node before the
        // caller decides whether the new source should play.
        #expect(!engine.state.isPlaying)
        #expect(!engine._hasActivePlayback)

        engine.play()
        engine.pause()
        await engine.awaitHybridWorkForTests()

        #expect(!engine.state.isPlaying)
        #expect(!engine._isStreamingMode)
        #expect(!engine._hasActivePlayback)
    }

    @Test("a slow stale load cannot overwrite the newer track")
    func staleLoadCannotOverwriteNewerTrack() async throws {
        let wav = try makeWAVFile(seconds: 2)
        let bridge = MockYTDlpBridge()
        let slowVideoId = "slow-\(UUID().uuidString)"
        let fastVideoId = "fast-\(UUID().uuidString)"
        let quality = UserDefaults.standard.string(forKey: PrefKey.ytAudioQuality) ?? "bestaudio"
        defer {
            MediaFileCache.remove(videoId: slowVideoId, quality: quality)
            MediaFileCache.remove(videoId: fastVideoId, quality: quality)
        }
        bridge.streamURLsByVideoId = [slowVideoId: wav, fastVideoId: wav]
        bridge.resolveDelaysByVideoId = [
            slowVideoId: 150_000_000,
            fastVideoId: 10_000_000
        ]
        let engine = YouTubeStreamEngine(
            bridge: bridge, cache: StreamURLCache(defaultTTL: 3600))
        let slow = TrackSnapshot(
            id: UUID(), title: "Slow A", artist: "a", albumTitle: nil,
            durationSeconds: 2, youTubeId: slowVideoId,
            artworkUrl: nil,
            sampleRate: 44_100, bitDepth: 16, codec: "aac", isLossless: false)
        let fast = TrackSnapshot(
            id: UUID(), title: "Fast B", artist: "a", albumTitle: nil,
            durationSeconds: 2, youTubeId: fastVideoId,
            artworkUrl: nil,
            sampleRate: 44_100, bitDepth: 16, codec: "aac", isLossless: false)

        let slowLoad = Task { try await engine.load(slow) }
        while !bridge.requestedVideoIds.contains(slowVideoId) { await Task.yield() }
        let fastLoad = Task { try await engine.load(fast) }
        try await fastLoad.value
        try await slowLoad.value

        #expect(engine.state.track?.id == fast.id)
        #expect(engine.state.track?.title == fast.title)
        #expect(!engine.state.buffering)
    }

    @Test("a new load cancels and invalidates an in-flight prefetch")
    func newLoadInvalidatesOldPrefetch() async throws {
        let wav = try makeWAVFile(seconds: 2)
        let bridge = MockYTDlpBridge()
        let prefetchVideoId = "prefetch-\(UUID().uuidString)"
        let currentVideoId = "current-\(UUID().uuidString)"
        let quality = UserDefaults.standard.string(forKey: PrefKey.ytAudioQuality) ?? "bestaudio"
        defer {
            MediaFileCache.remove(videoId: prefetchVideoId, quality: quality)
            MediaFileCache.remove(videoId: currentVideoId, quality: quality)
        }
        bridge.streamURLsByVideoId = [prefetchVideoId: wav, currentVideoId: wav]
        bridge.resolveDelaysByVideoId = [prefetchVideoId: 150_000_000]
        let engine = YouTubeStreamEngine(
            bridge: bridge, cache: StreamURLCache(defaultTTL: 3600))
        let prefetched = TrackSnapshot(
            id: UUID(), title: "Old Prefetch", artist: "a", albumTitle: nil,
            durationSeconds: 2, youTubeId: prefetchVideoId,
            artworkUrl: nil,
            sampleRate: 44_100, bitDepth: 16, codec: "aac", isLossless: false)
        let current = TrackSnapshot(
            id: UUID(), title: "Current", artist: "a", albumTitle: nil,
            durationSeconds: 2, youTubeId: currentVideoId,
            artworkUrl: nil,
            sampleRate: 44_100, bitDepth: 16, codec: "aac", isLossless: false)

        let prefetchTask = Task { await engine.prepare(prefetched) }
        while !bridge.requestedVideoIds.contains(prefetchVideoId) { await Task.yield() }
        try await engine.load(current)
        await prefetchTask.value

        #expect(engine.state.track?.id == current.id)
        #expect(!engine._isPrefetched)
    }
}

// MARK: - Mock YTDlpBridge

@MainActor
final class MockYTDlpBridge: YTDlpBridgeProtocol {
    var streamURL: URL?
    var streamURLsByVideoId: [String: URL] = [:]
    var resolveDelaysByVideoId: [String: UInt64] = [:]
    var requestedVideoIds: [String] = []
    var shouldFail = false
    var callCount = 0

    func resolveStreamURL(videoId: String, quality: String, timeout: TimeInterval) async throws -> URL {
        callCount += 1
        requestedVideoIds.append(videoId)
        if let delay = resolveDelaysByVideoId[videoId] {
            // Deliberately ignore cooperative cancellation. Generation gates,
            // not a well-behaved dependency, must protect observable state.
            try? await Task.sleep(nanoseconds: delay)
        }
        if shouldFail { throw YTDlpBridge.YTDlpError.notFound }
        return streamURLsByVideoId[videoId] ?? streamURL!
    }
    func fetchPlaylist(url: String, timeout: TimeInterval) async throws -> [YTDlpBridge.YTDlpPlaylistEntry] { [] }
    func searchYouTube(query: String, limit: Int, timeout: TimeInterval) async throws -> [YTDlpBridge.YTDlpPlaylistEntry] { [] }
    func version() async -> String? { "mock" }
}

// MARK: - WAV fixture generation

/// Generates a 44100Hz mono 16-bit sine WAV of the given duration and writes it to a temporary directory.
private func makeWAVFile(seconds: UInt32 = 1) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("muses-yt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("test.wav")

    let sampleRate: UInt32 = 44100
    let numChannels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let numSamples: UInt32 = sampleRate * seconds
    let dataSize = numSamples * UInt32(bitsPerSample) / 8 * UInt32(numChannels)

    var data = Data()
    // RIFF header
    data.append(contentsOf: "RIFF".utf8)
    data.append(contentsOf: uint32ToBytes(36 + dataSize))   // chunk size
    data.append(contentsOf: "WAVE".utf8)
    data.append(contentsOf: "fmt ".utf8)
    data.append(contentsOf: uint32ToBytes(16))               // subchunk1 size
    data.append(contentsOf: uint16ToBytes(1))               // PCM
    data.append(contentsOf: uint16ToBytes(numChannels))
    data.append(contentsOf: uint32ToBytes(sampleRate))
    data.append(contentsOf: uint32ToBytes(sampleRate * UInt32(bitsPerSample) * UInt32(numChannels) / 8)) // byte rate
    data.append(contentsOf: uint16ToBytes(numChannels * bitsPerSample / 8)) // block align
    data.append(contentsOf: uint16ToBytes(bitsPerSample))
    data.append(contentsOf: "data".utf8)
    data.append(contentsOf: uint32ToBytes(dataSize))
    // Sine samples (440Hz, amplitude 16000)
    for i in 0..<numSamples {
        let t = Double(i) / Double(sampleRate)
        let v = Int16(sin(2 * .pi * 440 * t) * 16000)
        data.append(contentsOf: int16ToBytes(v))
    }
    try data.write(to: url)
    return url
}

private func uint32ToBytes(_ v: UInt32) -> [UInt8] {
    withUnsafeBytes(of: v.littleEndian) { Array($0) }
}
private func uint16ToBytes(_ v: UInt16) -> [UInt8] {
    withUnsafeBytes(of: v.littleEndian) { Array($0) }
}
private func int16ToBytes(_ v: Int16) -> [UInt8] {
    withUnsafeBytes(of: v.littleEndian) { Array($0) }
}
