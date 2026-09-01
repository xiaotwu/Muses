import Foundation

@MainActor
protocol PlayerEngine: AnyObject {
    var state: PlayerState { get }
    /// Completion callback: invoked when the current track finishes playing
    /// (replacing the old isPlaying flip detection). Set by PlaybackService to
    /// advance the queue seamlessly and preload the next track.
    var onCompletion: (@MainActor () -> Void)? { get set }
    func load(_ track: TrackSnapshot) async throws
    /// Preloads the next track onto the standby player node (no scheduling, no playback).
    func prepare(_ track: TrackSnapshot) async
    /// Plays the preloaded track: schedules onto the inactive node, starts playback,
    /// swaps the nodes, and updates state. Returns true on a successful switch,
    /// false when there is no preloaded track.
    @discardableResult
    func playPrepared() -> Bool
    func play()
    func pause()
    func toggle()
    func seek(to time: Double)
    func setVolume(_ v: Float)
    func setEQ(_ bands: [EQBand])
    func installSpectrumTap(_ handler: @escaping (SpectrumFrame) -> Void)
    func removeSpectrumTap()
}