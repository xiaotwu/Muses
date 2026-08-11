import Testing
import Foundation
import AVFoundation
@testable import Muses

@MainActor
@Suite("SpectrumTap")
struct SpectrumTapTests {
    @Test("emits 64-band frames while playing")
    func emitsFrames() async throws {
        let wav = FileManager.default.temporaryDirectory.appending(path: "muses-spec-\(UUID().uuidString).wav")
        try makeSilentWav(at: wav, seconds: 2)
        let engine = LocalAudioEngine()
        let snap = TrackSnapshot(id: UUID(), title: "t", artist: "a", albumTitle: nil,
            durationSeconds: 2, filePath: wav.path, youTubeId: nil, artworkHash: nil,
            artworkUrl: nil, sampleRate: 44100, bitDepth: 16, codec: "pcm", isLossless: false)
        try await engine.load(snap)

        var received: SpectrumFrame?
        engine.installSpectrumTap { received = $0 }
        engine.play()
        // 等待若干帧
        try await Task.sleep(for: .milliseconds(300))
        engine.pause()
        #expect(received != nil)
        #expect(received?.bands.count == 64)
    }
}