import Testing
import Foundation
@testable import Muses

@MainActor
@Suite("LocalAudioEngine")
struct LocalAudioEngineTests {
    @Test("loads a wav and reports duration")
    func loadReportsDuration() async throws {
        let wav = FileManager.default.temporaryDirectory.appending(path: "muses-eng-\(UUID().uuidString).wav")
        try makeSilentWav(at: wav, seconds: 2)
        let engine = LocalAudioEngine()
        let snap = TrackSnapshot(
            id: UUID(), title: "t", artist: "a", albumTitle: nil,
            durationSeconds: 2, filePath: wav.path, youTubeId: nil,
            artworkHash: nil, artworkUrl: nil,
            sampleRate: 44100, bitDepth: 16, codec: "pcm", isLossless: false)
        try await engine.load(snap)
        #expect(engine.state.duration > 1.5)
        #expect(engine.state.source == .local)
    }

    @Test("play then pause flips isPlaying")
    func playPause() async throws {
        let wav = FileManager.default.temporaryDirectory.appending(path: "muses-eng-\(UUID().uuidString).wav")
        try makeSilentWav(at: wav, seconds: 1)
        let engine = LocalAudioEngine()
        let snap = TrackSnapshot(id: UUID(), title: "t", artist: "a", albumTitle: nil,
            durationSeconds: 1, filePath: wav.path, youTubeId: nil, artworkHash: nil,
            artworkUrl: nil, sampleRate: 44100, bitDepth: 16, codec: "pcm", isLossless: false)
        try await engine.load(snap)
        engine.play()
        #expect(engine.state.isPlaying)
        engine.pause()
        #expect(!engine.state.isPlaying)
    }
}