import Testing
import Foundation
import MediaPlayer
@testable import Muses

@MainActor
@Suite("NowPlayingManager")
struct NowPlayingManagerTests {
    @Test("manager updates nowPlayingInfo title after load")
    func updatesInfoAfterLoad() async throws {
        let wav = FileManager.default.temporaryDirectory
            .appending(path: "muses-npm-\(UUID().uuidString).wav")
        try makeSilentWav(at: wav, seconds: 1)
        let engine = LocalAudioEngine()
        let queue = QueueService()
        let playback = PlaybackService(localEngine: engine,
                                        youtubeEngine: RecordingEngine(),
                                        queue: queue)
        let manager = NowPlayingManager(playback)

        let snap = TrackSnapshot(id: UUID(), title: "MyTrack", artist: "Artist",
            albumTitle: "Album", durationSeconds: 1, filePath: wav.path,
            youTubeId: nil, artworkHash: nil, artworkUrl: nil,
            sampleRate: 44100, bitDepth: 16, codec: "pcm", isLossless: false)
        try await engine.load(snap)
        engine.play()

        // 给 manager 一点时间响应状态变化
        try await Task.sleep(for: .milliseconds(400))

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        #expect(info?[MPMediaItemPropertyTitle] as? String == "MyTrack")
        #expect(info?[MPMediaItemPropertyArtist] as? String == "Artist")

        engine.pause()
        _ = manager   // keep alive
    }

    @Test("manager init does not crash without track")
    func initNoTrack() async throws {
        let engine = LocalAudioEngine()
        let queue = QueueService()
        let playback = PlaybackService(localEngine: engine,
                                        youtubeEngine: RecordingEngine(),
                                        queue: queue)
        let manager = NowPlayingManager(playback)
        // 给 manager 一点时间执行初始 updateInfo
        try await Task.sleep(for: .milliseconds(100))
        _ = manager
        // 断言能构造且不崩溃即可(nowPlayingInfo 是系统单例, 跨测试可能残留)
    }
}