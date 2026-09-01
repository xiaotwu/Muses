import Foundation
@testable import Muses

/// Deterministic in-memory playback engine shared by behavioral tests.
@MainActor
final class RecordingEngine: PlayerEngine {
    let state = PlayerState()
    var loadCallCount = 0
    var lastLoadedTrack: TrackSnapshot?
    var playCallCount = 0
    var pauseCallCount = 0
    var toggleCallCount = 0
    var seekCallCount = 0
    var lastSeekTime: Double?
    var volumeSet: Float?
    var eqBands: [EQBand]?
    var spectrumTapInstalled = false
    var onCompletion: (@MainActor () -> Void)?
    var prepareCallCount = 0
    var lastPreparedTrack: TrackSnapshot?
    var playPreparedCallCount = 0
    var playPreparedReturnValue = false
    private var spectrumHandler: ((SpectrumFrame) -> Void)?

    func load(_ track: TrackSnapshot) async throws {
        loadCallCount += 1
        lastLoadedTrack = track
        state.track = track
        state.duration = track.durationSeconds
        state.position = 0
        state.isPlaying = true
    }

    func prepare(_ track: TrackSnapshot) async {
        prepareCallCount += 1
        lastPreparedTrack = track
    }

    @discardableResult
    func playPrepared() -> Bool {
        playPreparedCallCount += 1
        return playPreparedReturnValue
    }

    func play() { playCallCount += 1; state.isPlaying = true }
    func pause() { pauseCallCount += 1; state.isPlaying = false }
    func toggle() { toggleCallCount += 1; state.isPlaying.toggle() }
    func seek(to time: Double) { seekCallCount += 1; lastSeekTime = time; state.position = time }
    func setVolume(_ value: Float) { volumeSet = value }
    func setEQ(_ bands: [EQBand]) { eqBands = bands }
    func installSpectrumTap(_ handler: @escaping (SpectrumFrame) -> Void) {
        spectrumTapInstalled = true
        spectrumHandler = handler
    }
    func removeSpectrumTap() {
        spectrumTapInstalled = false
        spectrumHandler = nil
    }
}
