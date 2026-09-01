import SwiftUI
import AppKit

/// Circular artwork that rotates clockwise at a calm visual pace while playing.
/// No vinyl disc, grooves, or spindle. Reduce Motion: frozen.
struct VinylModeView: View {
    let source: ArtworkSource
    var size: CGFloat = 480
    @Environment(PlaybackService.self) private var playback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var accumulatedDegrees: Double = 0
    @State private var activeSince: Date?

    private var shouldRotate: Bool { playback.state.isPlaying && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                                paused: !shouldRotate)) { timeline in
            ArtworkView(source: source, cornerRadius: size / 2,
                        glyphSize: size * 0.17, targetSize: size)
                .clipShape(Circle())
                .rotationEffect(.degrees(VinylRotation.angle(
                    accumulatedDegrees: accumulatedDegrees,
                    activeSince: activeSince,
                    at: timeline.date,
                    isRotating: shouldRotate
                )))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .onAppear { synchronizeRotation(at: Date()) }
        .onChange(of: playback.state.isPlaying) { _, _ in
            synchronizeRotation(at: Date())
        }
        .onChange(of: reduceMotion) { _, _ in
            synchronizeRotation(at: Date())
        }
        .onChange(of: playback.state.track?.id) { _, _ in
            accumulatedDegrees = 0
            activeSince = shouldRotate ? Date() : nil
        }
    }

    private func synchronizeRotation(at date: Date) {
        if let activeSince {
            accumulatedDegrees = VinylRotation.angle(
                accumulatedDegrees: accumulatedDegrees,
                activeSince: activeSince,
                at: date,
                isRotating: true
            )
        }
        activeSince = shouldRotate ? date : nil
    }
}

/// Pure elapsed-time rotation math. Rendering cadence never changes the speed.
enum VinylRotation {
    /// The large artwork uses a restrained ambient rotation rather than a
    /// physical record speed, keeping lyrics and controls visually dominant.
    static let secondsPerRevolution: Double = 16
    static let rpm: Double = 60.0 / secondsPerRevolution
    static let degreesPerSecond = rpm * 360.0 / 60.0

    static func angle(accumulatedDegrees: Double,
                      activeSince: Date?,
                      at date: Date,
                      isRotating: Bool) -> Double {
        guard isRotating, let activeSince else {
            return normalized(accumulatedDegrees)
        }
        let elapsed = max(0, date.timeIntervalSince(activeSince))
        return normalized(accumulatedDegrees + elapsed * degreesPerSecond)
    }

    private static func normalized(_ angle: Double) -> Double {
        let value = angle.truncatingRemainder(dividingBy: 360)
        return value >= 0 ? value : value + 360
    }
}
