import Foundation

/// One visible iframe session. Native engine state stays independent; commands
/// and system metadata use this state only while the session owns transport.
@Observable
@MainActor
final class VideoPlaybackSession {
    let id = UUID()
    let videoId: String
    let initialStart: VideoPlaybackStart
    let state = PlayerState()
    var surface: VideoSurface?
    private var pendingPlaybackIntent: Bool? = nil
    private(set) var requestedPlay: Bool
    private(set) var volumeRevision = 0
    private(set) var seekRevision = 0
    private(set) var volume: Float
    private(set) var ready = false
    private(set) var closing = false
    private(set) var ended = false
    var sendCommand: ((String, Double?) -> Void)?
    var onClose: (() -> Void)?
    var onEnded: (() -> Void)?
    var onVolumeChange: ((Float) -> Void)?
    var onStateChange: ((Bool) -> Void)?

    init(videoId: String, track: TrackSnapshot?, start: VideoPlaybackStart) {
        self.videoId = videoId
        initialStart = start
        state.track = track
        state.position = start.position
        state.duration = track?.durationSeconds ?? 0
        state.buffering = true
        state.audioProcessing = .streamOnly
        requestedPlay = start.shouldPlay
        volume = Float(start.volumePercent) / 100
    }

    func setPlaying(_ playing: Bool) {
        guard !closing, state.error == nil else { return }
        requestedPlay = playing
        pendingPlaybackIntent = playing
        if !playing { state.isPlaying = false }
        if ready { sendCommand?(playing ? "play" : "pause", nil) }
    }

    func seek(to position: Double) {
        guard !closing, position.isFinite else { return }
        let target = max(0, state.duration > 0 ? min(position, state.duration) : position)
        seekRevision &+= 1
        state.position = target
        if ready { sendCommand?("seek", target) }
    }

    func setVolume(_ value: Float) {
        guard !closing, value.isFinite else { return }
        volumeRevision &+= 1
        volume = min(1, max(0, value))
        if ready { sendCommand?("volume", Double(volume) * 100) }
    }

    func receiveVolume(percent: Double, revision: Int? = nil) {
        guard revision == nil || revision == volumeRevision else { return }
        guard ready, !closing, state.error == nil, percent.isFinite,
              (0...100).contains(percent) else { return }
        let value = Float(percent / 100)
        guard abs(value - volume) > 0.001 else { return }
        volume = value
        onVolumeChange?(value)
    }

    func didBecomeReady() {
        guard !closing, state.error == nil else { return }
        ready = true
        state.buffering = false
        sendCommand?("initialize", nil)
    }

    func receive(position: Double, duration: Double, playerState: Int, positionRevision: Int? = nil) {
        guard ready, !closing, state.error == nil, [-1, 0, 1, 2, 3, 5].contains(playerState),
              position.isFinite, duration.isFinite,
              position >= 0, duration >= 0 else { return }
        let acceptsPosition = positionRevision == nil || positionRevision == seekRevision
        // A pre-seek completion cannot advance the collection after the user seeks back.
        if playerState == 0, !acceptsPosition { return }
        let wasPlaying = state.isPlaying
        if duration > 0 { state.duration = duration }
        // Cued/unstarted players may report zero until media is requested.
        if acceptsPosition, [0, 1, 2].contains(playerState), duration > 0 {
            state.position = min(position, duration)
        }
        state.buffering = playerState == 3
        let reportedPlaying = playerState == 1
        if playerState == 0 {
            pendingPlaybackIntent = nil
            requestedPlay = false
        } else if playerState == 1 || playerState == 2 {
            if let pendingPlaybackIntent {
                if reportedPlaying == pendingPlaybackIntent { self.pendingPlaybackIntent = nil }
            } else {
                requestedPlay = reportedPlaying
            }
        }
        // A packet already in flight must not undo a newer system pause/play command.
        state.isPlaying = reportedPlaying && requestedPlay
        let newlyEnded = playerState == 0 && !ended
        ended = playerState == 0
        if wasPlaying != state.isPlaying { onStateChange?(state.isPlaying) }
        if newlyEnded { onEnded?() }
    }

    func fail() {
        guard !closing else { return }
        state.error = .embedUnavailable
        state.buffering = false
        state.isPlaying = false
        requestedPlay = false
        pendingPlaybackIntent = nil
        sendCommand?("pause", nil)
        onStateChange?(false)
    }

    func requestClose() {
        guard !closing else { return }
        closing = true
        onClose?()
    }
}
