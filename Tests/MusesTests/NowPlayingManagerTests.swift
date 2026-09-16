import Testing
import Foundation
import MediaPlayer
import AppKit
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
            artworkLoader: { _ in nil },
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
            artworkLoader: { _ in nil },
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
            artworkLoader: { _ in nil },
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
            artworkLoader: { _ in nil },
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
    @Test("System media artwork rejects the previous track's delayed cover")
    func rejectsStaleArtwork() async throws {
        let engine = RecordingEngine()
        let playback = PlaybackService(youtubeEngine: engine, queue: QueueService())
        var requests: [String: CheckedContinuation<NSImage?, Never>] = [:]
        var published: [String: Any] = [:]
        let manager = NowPlayingManager(playback, bindsRemoteCommands: false,
            artworkLoader: { url in await withCheckedContinuation { requests[url.lastPathComponent] = $0 } },
            publishInfo: { published = $0 })
        func snapshot(_ name: String) -> TrackSnapshot {
            TrackSnapshot(id: UUID(), title: name, artist: "Artist", albumTitle: nil,
                          durationSeconds: 60, youTubeId: "test-video",
                          artworkUrl: "https://example.com/\(name)", sampleRate: nil,
                          bitDepth: nil, codec: nil, isLossless: false)
        }
        let first = snapshot("first"), second = snapshot("second")
        playback.playTrack(first, context: [first], from: .songs)
        let deadline = ContinuousClock.now + .seconds(3)
        while requests["first"] == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let firstRequest = try #require(requests["first"])
        #expect(published[MPMediaItemPropertyArtwork] is MPMediaItemArtwork)
        playback.playTrack(second, context: [second], from: .songs)
        while requests["second"] == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let secondRequest = try #require(requests["second"])
        secondRequest.resume(returning: NSImage(size: .init(width: 202, height: 202)))
        try await Task.sleep(for: .milliseconds(50))
        firstRequest.resume(returning: NSImage(size: .init(width: 101, height: 101)))
        try await Task.sleep(for: .milliseconds(50))
        #expect((published[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)?.image(at: NSSize(width: 300, height: 300))?.size.width == 202)
        #expect(published[MPMediaItemPropertyTitle] as? String == "second")
        withExtendedLifetime(manager) {}
    }

}
