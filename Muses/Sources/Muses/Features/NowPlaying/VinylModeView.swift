import SwiftUI
import AppKit

/// 唱片旋转模式: 圆形封面 + 中心唱片孔, 播放时以 33⅓ rpm 旋转, 暂停时停。
/// Reduce Motion 下静止不转。
struct VinylModeView: View {
    let source: ArtworkSource
    @Environment(PlaybackService.self) private var playback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = 0
    @State private var lastDate: Date = .distantPast

    // 33⅓ rpm = 360° / 1.8s
    private let rpm: Double = 33.0 + 1.0 / 3.0
    private let discSize: CGFloat = 480

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let _ = updateAngle(date: timeline.date)
            disc
                .rotationEffect(.degrees(angle))
        }
        .frame(width: discSize, height: discSize)
    }

    private var disc: some View {
        ZStack {
            // 唱片底盘(深色)
            Circle()
                .fill(
                    RadialGradient(colors: [Color.black, Color(white: 0.08)],
                                   center: .center,
                                   startRadius: discSize * 0.15,
                                   endRadius: discSize * 0.5)
                )
                .overlay(
                    // 唱片纹路(同心圆细线)
                    Canvas { ctx, size in
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)
                        let maxR = min(size.width, size.height) / 2
                        let grooveCount = 40
                        for i in 1...grooveCount {
                            let r = maxR * CGFloat(i) / CGFloat(grooveCount + 1)
                            ctx.stroke(
                                Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                                        width: r * 2, height: r * 2)),
                                with: .color(BrandColors.textPrimary.opacity(0.05)),
                                lineWidth: 0.5
                            )
                        }
                    }
                )

            // 封面(圆形, 居中, 占唱片 60%)
            artwork
                .frame(width: discSize * 0.6, height: discSize * 0.6)
                .clipShape(Circle())

            // 中心唱片孔
            Circle()
                .fill(Color.black)
                .frame(width: 60, height: 60)
            // 中心 magenta 标签点
            Circle()
                .fill(BrandColors.magenta)
                .frame(width: 8, height: 8)
        }
        .shadow(radius: 24)
    }

    @ViewBuilder
    private var artwork: some View {
        ArtworkView(source: source, cornerRadius: 0, glyphSize: 60)
    }

    /// 基于 TimelineView 的 date 累积旋转角度; 暂停或 Reduce Motion 时不增。
    private func updateAngle(date: Date) {
        guard !reduceMotion, playback.state.isPlaying else {
            lastDate = date
            return
        }
        let dt = max(0, min(1.0 / 10.0, date.timeIntervalSince(lastDate)))
        // 每秒旋转度数 = rpm / 60 * 360
        let degPerSec = rpm / 60.0 * 360.0
        angle = (angle + dt * degPerSec).truncatingRemainder(dividingBy: 360)
        lastDate = date
    }
}