import SwiftUI

/// Mirrored bar spectrum visualization: the upper half has 64 bars rising from
/// the midline (Apple Music accent fade), and the lower half mirrors them at
/// 30% opacity. With Reduce Motion enabled, the raw bands are drawn directly
/// with no peak decay.
///
/// Switches between Metal (MTKView hardware-accelerated) and Canvas (CPU-drawn)
/// based on `PrefKey.gpuAcceleration`.
struct SpectrumView: View {
    @Environment(PlaybackService.self) private var playback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PrefKey.gpuAcceleration) private var gpuAcceleration = true

    @State private var current: SpectrumFrame?
    @State private var peaks: [Float] = Array(repeating: 0, count: 64)
    @State private var lastFrameDate: Date = .distantPast

    private let bandCount = 64
    // Decays from 1.0 to 0 over 200ms.
    private let peakDecayPerSecond: Float = 1.0 / 0.2

    var body: some View {
        if gpuAcceleration {
            MetalSpectrumView()
                .frame(height: 120)
        } else {
            canvasSpectrum
        }
    }

    /// CPU-rendered spectrum via Canvas.
    private var canvasSpectrum: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                paused: reduceMotion || !playback.state.isPlaying)) { timeline in
            // Update peaks in the ViewBuilder closure (main thread, before
            // drawing) rather than writing @State during Canvas rendering.
            let decayed = updatePeaks(date: timeline.date)
            Canvas { ctx, size in
                drawSpectrum(ctx: ctx, size: size, values: decayed)
            }
        }
        .frame(height: 120)
        .onAppear {
            // The handler runs on the audio render thread; hop to the main
            // thread to write @State.
            playback.installSpectrumHandler { frame in
                DispatchQueue.main.async {
                    current = frame
                }
            }
        }
        .onDisappear {
            playback.removeSpectrumHandler()
        }
    }

    /// Uses the TimelineView date to compute the elapsed time, decaying the
    /// peaks and tracking the current bands. Returns the peak array to draw
    /// (a copy, avoiding @State mutation inside the Canvas).
    private func updatePeaks(date: Date) -> [Float] {
        let bands = current?.bands ?? Array(repeating: 0, count: bandCount)
        guard bands.count == bandCount else { return peaks }

        if reduceMotion {
            peaks = bands
            return peaks
        }

        let dt = max(0, min(1.0 / 10.0, date.timeIntervalSince(lastFrameDate)))
        let decay = peakDecayPerSecond * Float(dt)
        for i in 0..<bandCount {
            peaks[i] = max(bands[i], peaks[i] - decay)
        }
        lastFrameDate = date
        return peaks
    }

    /// Pure drawing: renders the mirrored bars from the precomputed values.
    /// Mutates no @State.
    private func drawSpectrum(ctx: GraphicsContext, size: CGSize, values: [Float]) {
        let width = size.width
        let height = size.height
        let midY = height / 2

        // Bar width: 80% fill, 20% gap.
        let totalGap = bandCount + 1
        let unit = width / CGFloat(totalGap)
        let barWidth = unit * 0.8
        let gap = unit * 0.2

        // A single Apple Music accent, with a vertical opacity gradient.
        let gradient = Gradient(colors: [BrandColors.magenta,
                                         BrandColors.magenta.opacity(0.55)])
        let shading = GraphicsContext.Shading.linearGradient(
            gradient, startPoint: CGPoint(x: 0, y: midY), endPoint: CGPoint(x: 0, y: 0)
        )
        let mirrorColor = BrandColors.magenta.opacity(0.3)

        for i in 0..<bandCount {
            let v = CGFloat(values[i])
            guard v > 0 else { continue }
            let barH = v * midY
            let x = unit + CGFloat(i) * (barWidth + gap)

            // Upper bar (rising from midY).
            let upper = CGRect(x: x, y: midY - barH, width: barWidth, height: barH)
            let upperPath = Path(roundedRect: upper, cornerRadius: 2)
            ctx.fill(upperPath, with: shading)

            // Lower mirror (from midY downward, 30% opacity).
            let lower = CGRect(x: x, y: midY, width: barWidth, height: barH)
            let lowerPath = Path(roundedRect: lower, cornerRadius: 2)
            ctx.fill(lowerPath, with: GraphicsContext.Shading.color(mirrorColor))
        }
    }
}
