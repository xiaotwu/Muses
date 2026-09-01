import Testing
import Foundation
import MediaPlayer
@testable import Muses

@MainActor
@Suite("NowPlayingManager", .serialized)
struct NowPlayingManagerTests {
    @Test("manager updates nowPlayingInfo title after load")
    func updatesInfoAfterLoad() async throws {
        let engine = RecordingEngine()
        let queue = QueueService()
        let playback = PlaybackService(youtubeEngine: engine, queue: queue)
        var published: [[String: Any]] = []
        let manager = NowPlayingManager(
            playback,
            bindsRemoteCommands: false,
            publishInfo: { published.append($0) }
        )

        let snap = TrackSnapshot(id: UUID(), title: "MyTrack", artist: "Artist",
            albumTitle: "Album", durationSeconds: 1,             youTubeId: "test-video", artworkUrl: nil,
            sampleRate: 44100, bitDepth: 16, codec: "pcm", isLossless: false)
        playback.playTrack(snap, context: [snap], from: .songs)

        // Poll the injected publication seam instead of assuming an AV engine and
        // the 250 ms observer both complete inside one fixed wall-clock delay.
        let deadline = ContinuousClock.now + .seconds(2)
        while published.last(where: { $0[MPMediaItemPropertyTitle] as? String == "MyTrack" }) == nil,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        let info = published.last { $0[MPMediaItemPropertyTitle] as? String == "MyTrack" }
        #expect(info?[MPMediaItemPropertyTitle] as? String == "MyTrack")
        #expect(info?[MPMediaItemPropertyArtist] as? String == "Artist")

        _ = manager   // keep alive
    }

    @Test("manager init does not crash without track")
    func initNoTrack() async throws {
        let engine = RecordingEngine()
        let queue = QueueService()
        let playback = PlaybackService(youtubeEngine: engine, queue: queue)
        let manager = NowPlayingManager(
            playback,
            bindsRemoteCommands: false,
            publishInfo: { _ in }
        )
        // Give the manager a moment to perform the initial updateInfo
        try await Task.sleep(for: .milliseconds(100))
        _ = manager
        // Just assert it constructs without crashing (nowPlayingInfo is a system singleton that may carry over across tests)
    }

    @Test("remote play and pause remain idempotent when commands repeat")
    func repeatedRemoteCommandsDoNotInvertPlayback() async throws {
        let engine = RecordingEngine()
        let playback = PlaybackService(youtubeEngine: engine, queue: QueueService())
        let manager = NowPlayingManager(
            playback,
            bindsRemoteCommands: false,
            publishInfo: { _ in }
        )
        let snap = TrackSnapshot(id: UUID(), title: "Remote", artist: "Artist",
            albumTitle: nil, durationSeconds: 10,             youTubeId: "test-video", artworkUrl: nil,
            sampleRate: 44_100, bitDepth: 16, codec: "pcm", isLossless: false)
        playback.playTrack(snap, context: [snap], from: .songs)
        try await Task.sleep(for: .milliseconds(100))
        #expect(engine.playCallCount == 1)

        manager.handleRemotePause()
        manager.handleRemotePause()
        #expect(!playback.state.isPlaying)
        #expect(engine.playCallCount == 1)

        manager.handleRemotePlay()
        manager.handleRemotePlay()
        #expect(playback.state.isPlaying)
        #expect(engine.playCallCount == 2)
    }

    @Test("rapid state changes keep one observation lifecycle")
    func rapidStateChangesKeepOneObservationLifecycle() async {
        let engine = RecordingEngine()
        let queue = QueueService()
        let playback = PlaybackService(youtubeEngine: engine, queue: queue)
        let manager = NowPlayingManager(
            playback,
            bindsRemoteCommands: false,
            publishInfo: { _ in }
        )

        // Starting again directly must also be idempotent.
        manager.startObserving()
        manager.startObserving()
        await Task.yield()

        // Simulates the high-frequency state the engine writes every 250ms; the old implementation spawned recursive Tasks here.
        for tick in 1...100 {
            engine.state.position = Double(tick) / 4
            engine.state.duration = 235 + Double(tick)
            engine.state.isPlaying.toggle()
            await Task.yield()
        }

        #expect(manager.observationLifecycleStartCount == 1)
    }
}
