import SwiftUI

/// A finite, center-out ember edge confirms hero-card playback. It neither
/// delays the command nor allocates an idle timer or a per-card particle loop.
struct CollectionActivationEmbers: View, Animatable {
    nonisolated var progress: CGFloat

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let p = min(1, max(0, progress))
            guard p > 0, p < 1 else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = hypot(size.width, size.height) * 0.56 * p
            let opacity = Double(sin(.pi * p)) * 0.8
            var edge = Path()
            for index in 0...96 {
                let angle = CGFloat(index) / 96 * .pi * 2
                let ripple = sin(angle * 13 + p * 8) * 3 + cos(angle * 23) * 2
                let point = CGPoint(x: center.x + cos(angle) * (radius + ripple),
                                    y: center.y + sin(angle) * (radius + ripple))
                if index == 0 { edge.move(to: point) } else { edge.addLine(to: point) }
            }
            edge.closeSubpath()
            context.stroke(edge, with: .color(.orange.opacity(opacity * 0.25)), lineWidth: 10)
            context.stroke(edge, with: .color(BrandColors.accent.opacity(opacity)), lineWidth: 3)
            context.stroke(edge, with: .color(.yellow.opacity(opacity)), lineWidth: 1)
            for index in 0..<24 {
                let angle = CGFloat(index) * 2.39996
                let distance = radius + CGFloat(index % 5) * 3 * p
                let point = CGPoint(x: center.x + cos(angle) * distance,
                                    y: center.y + sin(angle) * distance - 12 * p * p)
                let spark = CGRect(x: point.x, y: point.y, width: 1.5, height: 3)
                context.fill(Path(ellipseIn: spark), with: .color(.orange.opacity(opacity)))
            }
        }
    }
}
