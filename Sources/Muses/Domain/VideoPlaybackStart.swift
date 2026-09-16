import Foundation

/// Immutable handoff values; no engine or SwiftData object crosses into WebKit.
struct VideoPlaybackStart: Equatable, Sendable {
    let position: Double
    let shouldPlay: Bool
    let volumePercent: Int

    init(position: Double = 0, shouldPlay: Bool = false, volume: Float = 0.8) {
        self.position = position.isFinite ? max(0, position) : 0
        self.shouldPlay = shouldPlay
        self.volumePercent = volume.isFinite ? Int((max(0, min(1, volume)) * 100).rounded()) : 0
    }
}
