import SwiftUI

/// 整轨波形缩略图(2000 桶, 来自 WaveformCache), 已播放部分用 magenta 高亮,
/// 未播放部分用 textSecondary 30% 透明。支持拖动定位(DragGesture 实时预览, 松手 seek)。
struct WaveformView: View {
    @Environment(PlaybackService.self) private var playback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var peaks: [Float] = []
    @State private var trackId: UUID?
    @State private var dragRatio: Double?
    @State private var cachePolling = false

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                    paused: reduceMotion || !playback.state.isPlaying)) { _ in
                Canvas { ctx, size in
                    drawWaveform(ctx: ctx, size: size)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let w = geo.size.width
                        guard w > 0 else { return }
                        dragRatio = min(1, max(0, Double(v.location.x / w)))
                    }
                    .onEnded { v in
                        let w = geo.size.width
                        guard w > 0 else { return }
                        let ratio = min(1, max(0, Double(v.location.x / w)))
                        let dur = playback.state.duration
                        guard dur > 0 else { return }
                        playback.seek(to: ratio * dur)
                        dragRatio = nil
                    }
            )
        }
        .frame(height: 60)
        .onAppear { reload() }
        .onChange(of: playback.state.track?.id) {
            dragRatio = nil
            reload()
        }
    }

    /// 从 WaveformCache 加载当前曲目的波形; 无曲目或未缓存则清空并尝试轮询等待后台预计算。
    private func reload() {
        let id = playback.state.track?.id
        trackId = id
        if let id, let cached = WaveformCache.default.load(forTrackId: id) {
            peaks = cached
            cachePolling = false
        } else {
            peaks = []
            // 后台 detach Task 可能尚未写完缓存; 轻量轮询直到命中
            cachePolling = (id != nil)
        }
    }

    private func drawWaveform(ctx: GraphicsContext, size: CGSize) {
        // 缓存轮询: 后台预计算完成后补载
        if cachePolling, let id = trackId,
           let cached = WaveformCache.default.load(forTrackId: id) {
            peaks = cached
            cachePolling = false
        }

        let n = peaks.count
        guard n > 0 else { return }

        let width = size.width
        let height = size.height
        let midY = height / 2

        // 已播放桶索引: 拖动预览优先,否则基于播放进度
        let dur = playback.state.duration
        let pos = playback.state.position
        let progress: Double
        if let r = dragRatio {
            progress = r
        } else if dur > 0 {
            progress = pos / dur
        } else {
            progress = 0
        }
        let playedIdx = min(n, max(0, Int(Double(n) * progress)))

        let unit = width / CGFloat(n)
        let barWidth = max(1, unit * 0.8)
        let playedShading = GraphicsContext.Shading.color(BrandColors.magenta)
        let unplayedShading = GraphicsContext.Shading.color(BrandColors.textSecondary.opacity(0.3))

        for i in 0..<n {
            let v = CGFloat(peaks[i])
            let barH = v * height
            guard barH > 0 else { continue }
            let x = CGFloat(i) * unit
            let rect = CGRect(x: x, y: midY - barH / 2, width: barWidth, height: barH)
            let path = Path(roundedRect: rect, cornerRadius: 1)
            ctx.fill(path, with: i < playedIdx ? playedShading : unplayedShading)
        }
    }
}
