import SwiftUI

/// 镜像柱状频谱可视化: 上半部分 64 段从 midline 向上(Apple Music accent fade),
/// 下半部分以 30% 透明度镜像反射。开启 Reduce Motion 时直接绘制原始频段,不做峰值衰减。
///
/// 根据 `PrefKey.gpuAcceleration` 在 Metal(MTKView 硬件加速)与 Canvas(CPU 绘制)之间切换。
struct SpectrumView: View {
    @Environment(PlaybackService.self) private var playback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PrefKey.gpuAcceleration) private var gpuAcceleration = true

    @State private var current: SpectrumFrame?
    @State private var peaks: [Float] = Array(repeating: 0, count: 64)
    @State private var lastFrameDate: Date = .distantPast

    private let bandCount = 64
    // 200ms 内从 1.0 衰减到 0
    private let peakDecayPerSecond: Float = 1.0 / 0.2

    var body: some View {
        if gpuAcceleration {
            MetalSpectrumView()
                .frame(height: 120)
        } else {
            canvasSpectrum
        }
    }

    /// Canvas(CPU)渲染的频谱。
    private var canvasSpectrum: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                paused: reduceMotion || !playback.state.isPlaying)) { timeline in
            // 在 ViewBuilder 闭包里(主线程、渲染前)更新峰值,避免在 Canvas 绘制期间写 @State
            let decayed = updatePeaks(date: timeline.date)
            Canvas { ctx, size in
                drawSpectrum(ctx: ctx, size: size, values: decayed)
            }
        }
        .frame(height: 120)
        .onAppear {
            // handler 在音频渲染线程调用, 跳回主线程写入 @State
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

    /// 基于 TimelineView 的 date 计算时间增量,衰减峰值并跟随当前频段。
    /// 返回用于绘制的峰值数组(拷贝,避免在 Canvas 里改 @State)。
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

    /// 纯绘制:根据已算好的 values 画镜像柱。不修改任何 @State。
    private func drawSpectrum(ctx: GraphicsContext, size: CGSize, values: [Float]) {
        let width = size.width
        let height = size.height
        let midY = height / 2

        // 柱宽: 填充 80%, 间隙 20%
        let totalGap = bandCount + 1
        let unit = width / CGFloat(totalGap)
        let barWidth = unit * 0.8
        let gap = unit * 0.2

        // 单一 Apple Music accent 的竖直透明度渐变。
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

            // 上半柱(从 midY 向上)
            let upper = CGRect(x: x, y: midY - barH, width: barWidth, height: barH)
            let upperPath = Path(roundedRect: upper, cornerRadius: 2)
            ctx.fill(upperPath, with: shading)

            // 下半镜像(从 midY 向下, 30% 透明)
            let lower = CGRect(x: x, y: midY, width: barWidth, height: barH)
            let lowerPath = Path(roundedRect: lower, cornerRadius: 2)
            ctx.fill(lowerPath, with: GraphicsContext.Shading.color(mirrorColor))
        }
    }
}
