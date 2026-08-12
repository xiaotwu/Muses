import Testing
import Foundation
@testable import Muses

@MainActor
@Suite("YouTubeStreamEngine")
struct YouTubeStreamEngineTests {

    // MARK: - 1. load 成功设置 state.source = .youtube

    @Test("load 成功设置 state.source = .youtube 且 duration > 0")
    func loadSuccessSetsSource() async throws {
        let wav = try makeWAVFile()
        let bridge = MockYTDlpBridge()
        bridge.streamURL = wav
        let engine = YouTubeStreamEngine(bridge: bridge, cache: StreamURLCache(defaultTTL: 3600))
        let snap = TrackSnapshot(
            id: UUID(), title: "t", artist: "a", albumTitle: nil,
            durationSeconds: 1, filePath: nil, youTubeId: "vid1",
            artworkHash: nil, artworkUrl: nil,
            sampleRate: 44100, bitDepth: 16, codec: "aac", isLossless: false)
        try await engine.load(snap)
        #expect(engine.state.source == .youtube)
        #expect(engine.state.duration > 0)
        #expect(engine.state.error == nil)
        #expect(engine.state.buffering == false)
        #expect(!engine.isInFallbackMode)
    }

    // MARK: - 2. load 失败设置 state.error = .sourceUnavailable

    @Test("load 失败设置 state.error = .sourceUnavailable")
    func loadFailureSetsError() async throws {
        let bridge = MockYTDlpBridge()
        bridge.shouldFail = true
        let engine = YouTubeStreamEngine(bridge: bridge, cache: StreamURLCache(defaultTTL: 3600))
        let snap = TrackSnapshot(
            id: UUID(), title: "t", artist: "a", albumTitle: nil,
            durationSeconds: 1, filePath: nil, youTubeId: "vid2",
            artworkHash: nil, artworkUrl: nil,
            sampleRate: 44100, bitDepth: 16, codec: "aac", isLossless: false)
        do {
            try await engine.load(snap)
            Issue.record("应抛出 PlayerError.sourceUnavailable")
        } catch {
            #expect(engine.state.error == .sourceUnavailable)
        }
        #expect(engine.state.buffering == false)
    }

    // MARK: - 3. buffering 在 load 成功/失败后归零(覆盖于 1/2,这里单独断言)

    @Test("load 成功后 buffering == false")
    func bufferingFalseAfterSuccess() async throws {
        let wav = try makeWAVFile()
        let bridge = MockYTDlpBridge()
        bridge.streamURL = wav
        let engine = YouTubeStreamEngine(bridge: bridge, cache: StreamURLCache(defaultTTL: 3600))
        let snap = TrackSnapshot(
            id: UUID(), title: "t", artist: "a", albumTitle: nil,
            durationSeconds: 1, filePath: nil, youTubeId: "vid3",
            artworkHash: nil, artworkUrl: nil,
            sampleRate: 44100, bitDepth: 16, codec: "aac", isLossless: false)
        try await engine.load(snap)
        #expect(engine.state.buffering == false)
    }

    // MARK: - 4. AVPlayer 降级路径

    @Test("下载失败时降级到 AVPlayer 且不报错")
    func avPlayerFallback() async throws {
        let bridge = MockYTDlpBridge()
        // 用 .test TLD,DNS 解析会快速失败;配合短超时
        bridge.streamURL = URL(string: "https://invalid.example.test/audio.m4a")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1
        config.timeoutIntervalForResource = 2
        let session = URLSession(configuration: config)
        let engine = YouTubeStreamEngine(
            bridge: bridge, cache: StreamURLCache(defaultTTL: 3600), session: session)
        let snap = TrackSnapshot(
            id: UUID(), title: "t", artist: "a", albumTitle: nil,
            durationSeconds: 1, filePath: nil, youTubeId: "vid4",
            artworkHash: nil, artworkUrl: nil,
            sampleRate: 44100, bitDepth: 16, codec: "aac", isLossless: false)
        try await engine.load(snap)
        #expect(engine.state.source == .youtube)
        #expect(engine.state.error == nil)
        #expect(engine.isInFallbackMode)
        #expect(engine.state.buffering == false)
    }
}

// MARK: - Mock YTDlpBridge

@MainActor
final class MockYTDlpBridge: YTDlpBridgeProtocol {
    var streamURL: URL?
    var shouldFail = false
    var callCount = 0

    func resolveStreamURL(videoId: String, quality: String, timeout: TimeInterval) async throws -> URL {
        callCount += 1
        if shouldFail { throw YTDlpBridge.YTDlpError.notFound }
        return streamURL!
    }
    func fetchPlaylist(url: String, timeout: TimeInterval) async throws -> [YTDlpBridge.YTDlpPlaylistEntry] { [] }
    func searchYouTube(query: String, limit: Int, timeout: TimeInterval) async throws -> [YTDlpBridge.YTDlpPlaylistEntry] { [] }
    func version() async -> String? { "mock" }
}

// MARK: - WAV fixture 生成

/// 生成 1 秒 44100Hz mono 16-bit 正弦 WAV,写入临时目录。
private func makeWAVFile() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("muses-yt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("test.wav")

    let sampleRate: UInt32 = 44100
    let numChannels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let numSamples: UInt32 = sampleRate // 1 秒
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
    // 正弦波样本(440Hz, 振幅 16000)
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