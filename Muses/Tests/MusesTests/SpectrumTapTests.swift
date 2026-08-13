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
        // macOS 26.5: AVAudioPlayerNode.play() 曾在命令行进程抛 ObjC NSException,
        // 但 ensureEngineRunning() 现在用 RunLoop 自旋等待 IO 周期就绪后再 play(),
        // 渲染线程真实拉取样本,频谱 tap 产出 64 帧数据。无需 withKnownIssue。
        #expect(received != nil)
        #expect(received?.bands.count == 64)
    }
}