import Foundation
import Testing
@testable import Muses

@MainActor
@Suite("Prepared playback identity")
struct PreparedPlaybackIdentityTests {
    @Test("changing repeat mode cannot play a stale prefetched track")
    func repeatChangeFallsBackToNextTrack() async throws {
        let engine = RecordingEngine()
        engine.playPreparedReturnValue = true
        let queue = QueueService()
        queue.setRepeat(.one)
        let playback = PlaybackService(engine: engine, queue: queue)
        let first = track("first")
        let second = track("second")

        playback.playTrack(first, context: [first, second], from: .songs)
        for _ in 0..<200 where engine.lastPreparedTrack?.id != first.id {
            await Task.yield()
        }
        #expect(engine.lastPreparedTrack?.id == first.id)

        queue.setRepeat(.off)
        engine.state.position = engine.state.duration
        engine.state.isPlaying = false
        engine.onCompletion?()
        for _ in 0..<200 where engine.state.track?.id != second.id {
            await Task.yield()
        }

        #expect(engine.lastPreparedExpectedTrackID == second.id)
        #expect(engine.playPreparedCallCount == 1)
        #expect(engine.loadCallCount == 2)
        #expect(engine.state.track?.id == second.id)
        #expect(queue.current()?.track.id == second.id)
    }

    private func track(_ name: String) -> TrackSnapshot {
        TrackSnapshot(
            id: UUID(), title: name, artist: "Artist", albumTitle: nil,
            durationSeconds: 120, youTubeId: name, artworkUrl: nil,
            sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false)
    }
}
