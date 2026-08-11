import Testing
import Foundation
@testable import Muses

@MainActor
@Suite("PlaybackService")
struct PlaybackServiceTests {
    private func snap(_ t: String, path: String) -> TrackSnapshot {
        TrackSnapshot(id: UUID(), title: t, artist: "a", albumTitle: nil,
                      durationSeconds: 1, filePath: path, youTubeId: nil,
                      artworkHash: nil, artworkUrl: nil, sampleRate: 44100,
                      bitDepth: 16, codec: "pcm", isLossless: false)
    }

    @Test("playTrack loads first track and sets state")
    func playTrackLoads() async throws {
        let wav = FileManager.default.temporaryDirectory.appending(path: "muses-pb-\(UUID().uuidString).wav")
        try makeSilentWav(at: wav, seconds: 1)
        let a = snap("a", path: wav.path)
        let engine = LocalAudioEngine()
        let queue = QueueService()
        let svc = PlaybackService(engine: engine, queue: queue)
        svc.playTrack(a, context: [a], from: .album)
        // playTrack fires an async load; give it a tick
        try await Task.sleep(for: .milliseconds(100))
        #expect(svc.state.track?.title == "a")
        #expect(svc.queue.current()?.track.title == "a")
    }

    @Test("next advances to second track")
    func nextAdvances() async throws {
        let wav = FileManager.default.temporaryDirectory.appending(path: "muses-pb-\(UUID().uuidString).wav")
        try makeSilentWav(at: wav, seconds: 1)
        let a = snap("a", path: wav.path), b = snap("b", path: wav.path)
        let engine = LocalAudioEngine()
        let queue = QueueService()
        let svc = PlaybackService(engine: engine, queue: queue)
        svc.playTrack(a, context: [a, b], from: .album)
        try await Task.sleep(for: .milliseconds(100))
        #expect(svc.state.track?.title == "a")
        svc.next()
        try await Task.sleep(for: .milliseconds(100))
        #expect(svc.state.track?.title == "b")
    }

    @Test("setVolume clamps and persists")
    func setVolumeClamps() {
        let engine = LocalAudioEngine()
        let queue = QueueService()
        let svc = PlaybackService(engine: engine, queue: queue)
        svc.setVolume(2.0)
        #expect(svc.volume == 1.0)
        svc.setVolume(-1.0)
        #expect(svc.volume == 0.0)
        svc.setVolume(0.5)
        #expect(svc.volume == 0.5)
    }

    @Test("previous reloads prior track")
    func previousReloads() async throws {
        let wav = FileManager.default.temporaryDirectory.appending(path: "muses-pb-\(UUID().uuidString).wav")
        try makeSilentWav(at: wav, seconds: 1)
        let a = snap("a", path: wav.path), b = snap("b", path: wav.path)
        let engine = LocalAudioEngine()
        let queue = QueueService()
        let svc = PlaybackService(engine: engine, queue: queue)
        svc.playTrack(a, context: [a, b], from: .album)
        try await Task.sleep(for: .milliseconds(100))
        svc.next()
        try await Task.sleep(for: .milliseconds(100))
        #expect(svc.state.track?.title == "b")
        svc.previous()
        try await Task.sleep(for: .milliseconds(100))
        #expect(svc.state.track?.title == "a")
    }
}