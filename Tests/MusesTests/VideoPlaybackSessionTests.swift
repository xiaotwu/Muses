import Foundation
import Testing
@testable import Muses

@MainActor
@Suite("Video transport ownership")
struct VideoPlaybackSessionTests {
    @Test("old progress and completion cannot undo a newer seek or end its collection")
    func seekAcknowledgment() {
        let session = VideoPlaybackSession(videoId: "video00000a", track: nil,
            start: .init(position: 0, shouldPlay: false))
        var ended = false
        session.onEnded = { ended = true }
        session.didBecomeReady()
        let previous = session.seekRevision
        session.seek(to: 64)
        session.receive(position: 5, duration: 180, playerState: 2, positionRevision: previous)
        #expect(session.state.position == 64)
        session.receive(position: 180, duration: 180, playerState: 0, positionRevision: previous)
        #expect(!ended)
        session.receive(position: 1, duration: 180, playerState: 2, positionRevision: -1)
        #expect(session.state.position == 64)
        session.receive(position: 64.2, duration: 180, playerState: 2, positionRevision: session.seekRevision)
        #expect(session.state.position == 64.2)
        #expect(!session.state.isPlaying)
    }

    @Test("old iframe volume packets cannot undo a newer app volume command")
    func volumeAcknowledgment() {
        let session = VideoPlaybackSession(videoId: "video00000a", track: nil,
            start: .init(position: 0, shouldPlay: false))
        session.didBecomeReady()
        let previousRevision = session.volumeRevision
        session.setVolume(0.2)
        session.receiveVolume(percent: 80, revision: previousRevision)
        #expect(session.volume == 0.2)
        session.receiveVolume(percent: 35, revision: session.volumeRevision)
        #expect(session.volume == 0.35)
        session.requestClose()
        session.receiveVolume(percent: 90, revision: session.volumeRevision)
        #expect(session.volume == 0.35)
    }

    @Test("primary activation distinguishes buffering intent, paused and retry without replacing queue")
    func primaryActivationStates() async {
        let (playback, engine) = fixture()
        let track = engine.state.track!
        playback.queue.play(track, context: [track], from: .songs)
        engine.state.buffering = true
        playback.play()
        #expect(playback.primaryAction == .pause)
        playback.toggle()
        #expect(playback.primaryAction == .play)
        engine.state.buffering = false
        engine.state.error = .embedUnavailable
        #expect(playback.primaryAction == .retry)
        playback.toggle()
        for _ in 0..<100 where engine.loadCallCount == 0 { await Task.yield() }
        #expect(engine.loadCallCount == 1)
        #expect(playback.queue.current()?.track.id == track.id)
        playback.pause()
    }
    @Test("commands during loading initialize the latest intent, and rapid closed sessions reject late readiness")
    func loadingAndRapidClose() {
        let (playback, engine) = fixture()
        let originalVolume = playback.volume
        defer { playback.setVolume(originalVolume) }
        for index in 0..<200 {
            let session = playback.beginVideoSession(videoId: "video00000a")
            playback.seek(to: 64)
            playback.play()
            playback.pause()
            playback.setVolume(0.4)
            var initialized = false
            session.sendCommand = { name, _ in
                if name == "initialize" {
                    initialized = true
                    #expect(session.state.position == 64)
                    #expect(!session.requestedPlay)
                    #expect(session.volume == 0.4)
                }
            }
            if index.isMultiple(of: 2) { session.didBecomeReady(); #expect(initialized) }
            session.requestClose()
            playback.finishVideoSession(session, resume: true)
            session.didBecomeReady()
            session.receive(position: 180, duration: 200, playerState: 1)
            #expect(!engine.state.isPlaying)
            #expect(engine.state.position == 64)
            #expect(playback.videoSession == nil)
            session.sendCommand = nil
        }
    }

    @Test("in-flight iframe state cannot undo a newer system pause or play")
    func commandAcknowledgment() {
        let session = VideoPlaybackSession(videoId: "video00000a", track: nil,
            start: .init(position: 64, shouldPlay: true))
        session.didBecomeReady()
        session.receive(position: 64, duration: 200, playerState: 1)
        session.setPlaying(false)
        session.receive(position: 65, duration: 200, playerState: 1)
        #expect(!session.requestedPlay)
        #expect(!session.state.isPlaying)
        session.receive(position: 65, duration: 200, playerState: 2)
        session.setPlaying(true)
        session.receive(position: 65, duration: 200, playerState: 2)
        #expect(session.requestedPlay)
        session.receive(position: 66, duration: 200, playerState: 1)
        #expect(session.state.isPlaying)
        // Once acknowledged, direct iframe user controls are authoritative again.
        session.receive(position: 66, duration: 200, playerState: 2)
        #expect(!session.requestedPlay)
    }

    private func fixture() -> (PlaybackService, RecordingEngine) {
        let engine = RecordingEngine()
        engine.state.track = TrackSnapshot(
            id: UUID(), title: "Video", artist: "Artist", albumTitle: nil,
            durationSeconds: 200, youTubeId: "video00000a", artworkUrl: nil,
            sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false)
        engine.state.duration = 200
        engine.state.position = 64
        return (PlaybackService(engine: engine, queue: QueueService()), engine)
    }

    @Test("system transport controls video while native remains silent; return seeks once")
    func routesCommandsAndReturnsPosition() {
        let (playback, engine) = fixture()
        playback.play()
        let session = playback.beginVideoSession(videoId: "video00000a")
        var commands: [String] = []
        session.sendCommand = { name, _ in commands.append(name) }
        session.didBecomeReady()
        #expect(commands == ["initialize"])
        #expect(!engine.state.isPlaying)
        let playCount = engine.playCallCount
        playback.pause()
        #expect(commands.last == "pause")
        playback.play()
        #expect(commands.last == "play")
        #expect(engine.playCallCount == playCount)
        playback.seek(to: 80)
        #expect(commands.last == "seek")
        #expect(engine.state.position == 64)
        session.receive(position: 81, duration: 200, playerState: 1)
        #expect(playback.transportState.position == 81)
        #expect(playback.transportState.isPlaying)
        #expect(!engine.state.isPlaying)
        session.requestClose()
        #expect(engine.playCallCount == playCount)
        playback.finishVideoSession(session, resume: true)
        #expect(engine.state.position == 81)
        #expect(engine.state.isPlaying)
        #expect(playback.videoSession == nil)
        playback.pause()
    }

    @Test("iframe volume updates native preferences without echo; stale values are rejected")
    func iframeVolume() {
        let (playback, _) = fixture()
        let original = playback.volume
        defer { playback.setVolume(original) }
        let first = playback.beginVideoSession(videoId: "video00000a")
        first.didBecomeReady()
        var commands = 0
        first.sendCommand = { _, _ in commands += 1 }
        first.receiveVolume(percent: 37)
        #expect(abs(playback.volume - 0.37) < 0.001)
        #expect(commands == 0)
        first.receiveVolume(percent: .nan)
        first.receiveVolume(percent: 101)
        #expect(abs(playback.volume - 0.37) < 0.001)
        first.receiveVolume(percent: 0)
        #expect(playback.volume == 0)
        let second = playback.beginVideoSession(videoId: "video00000a")
        first.receiveVolume(percent: 90)
        #expect(playback.volume == 0)
        playback.finishVideoSession(first, resume: false)
        playback.finishVideoSession(second, resume: false)
    }

    @Test("stale teardown and packets cannot seek or resume a replacement session")
    func replacementIsolation() {
        let (playback, engine) = fixture()
        playback.play()
        let first = playback.beginVideoSession(videoId: "video00000a")
        first.didBecomeReady()
        first.receive(position: 90, duration: 200, playerState: 1)
        let second = playback.beginVideoSession(videoId: "video00000a")
        second.didBecomeReady()
        second.receive(position: 110, duration: 200, playerState: 2)
        first.receive(position: 150, duration: 200, playerState: 1)
        playback.finishVideoSession(first, resume: true)
        #expect(playback.videoSession === second)
        #expect(playback.transportState.position == 110)
        #expect(!engine.state.isPlaying)
        playback.finishVideoSession(second, resume: true)
        #expect(engine.state.position == 110)
        #expect(!engine.state.isPlaying)
        let seeks = engine.seekCallCount
        playback.finishVideoSession(first, resume: true)
        #expect(engine.seekCallCount == seeks)
    }

    @Test("invalid packets, cued zero and closing packets do not overwrite the handoff")
    func rejectsInvalidProgress() {
        let session = VideoPlaybackSession(videoId: "video00000a", track: nil,
            start: VideoPlaybackStart(position: 64, shouldPlay: false))
        session.didBecomeReady()
        session.receive(position: 0, duration: 200, playerState: 5)
        session.receive(position: .nan, duration: 200, playerState: 1)
        session.receive(position: -1, duration: 200, playerState: 1)
        #expect(session.state.position == 64)
        session.requestClose()
        session.receive(position: 150, duration: 200, playerState: 1)
        #expect(session.state.position == 64)
    }

    @Test("failed video stays paused on return and completion is delivered once")
    func failureAndCompletion() {
        let (playback, engine) = fixture()
        playback.play()
        let session = playback.beginVideoSession(videoId: "video00000a")
        session.didBecomeReady()
        session.fail()
        playback.finishVideoSession(session, resume: true)
        #expect(!engine.state.isPlaying)
        #expect(engine.state.position == 64)
        let completed = VideoPlaybackSession(videoId: "video00000a", track: nil,
            start: VideoPlaybackStart())
        var count = 0
        completed.onEnded = { count += 1 }
        completed.didBecomeReady()
        completed.receive(position: 200, duration: 200, playerState: 0)
        completed.receive(position: 200, duration: 200, playerState: 0)
        #expect(count == 1)
        #expect(!completed.requestedPlay)
    }
    @Test("late readiness after failure and unrelated video cannot overwrite native position")
    func failureAndIdentityBoundaries() {
        let failed = VideoPlaybackSession(videoId: "video00000a", track: nil, start: .init())
        var commands: [String] = []
        failed.sendCommand = { name, _ in commands.append(name) }
        failed.fail()
        failed.didBecomeReady()
        failed.setPlaying(true)
        #expect(!failed.ready)
        #expect(!commands.contains("initialize"))
        #expect(!commands.contains("play"))
        let (playback, engine) = fixture()
        let unrelated = playback.beginVideoSession(videoId: "video00000b")
        #expect(unrelated.state.track == nil)
        unrelated.didBecomeReady()
        unrelated.receive(position: 150, duration: 200, playerState: 2)
        playback.finishVideoSession(unrelated, resume: true)
        #expect(engine.state.position == 64)
        #expect(playback.videoSession == nil)
    }

    @Test("natural video completion advances collection queue exactly once")
    func completionAdvancesQueue() throws {
        let (playback, engine) = fixture()
        let first = try #require(engine.state.track)
        let second = TrackSnapshot(
            id: UUID(), title: "Next", artist: "Artist", albumTitle: nil,
            durationSeconds: 200, youTubeId: "video00000b", artworkUrl: nil,
            sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false)
        playback.queue.play(first, context: [first, second], from: .songs)
        playback.play()
        var completions = 0
        let token = playback.eventBus.subscribe { event in
            if case .trackCompleted = event { completions += 1 }
        }
        defer { playback.eventBus.unsubscribe(token) }
        let session = playback.beginVideoSession(videoId: "video00000a")
        session.didBecomeReady()
        session.receive(position: 200, duration: 200, playerState: 0)
        #expect(session.closing)
        #expect(playback.queue.current()?.track.id == first.id)
        playback.finishVideoSession(session, resume: true)
        #expect(playback.queue.current()?.track.id == second.id)
        #expect(completions == 1)
        playback.finishVideoSession(session, resume: true)
        #expect(completions == 1)
        playback.pause()
    }

}
