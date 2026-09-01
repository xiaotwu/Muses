### Task 3: SpectrumView + WaveformView 组件

**Files:**
- Create: `Muses/Sources/Muses/Features/NowPlaying/SpectrumView.swift`
- Create: `Muses/Sources/Muses/Features/NowPlaying/WaveformView.swift`

**Interfaces:**
- Consumes: `SpectrumFrame`(Domain)、`PlaybackService`(@Observable via `@Environment`)、`WaveformCache.default`(Infrastructure)、`BrandColors`(RootView)
- Produces:
  - `SpectrumView` — 镜像条形频谱,64 段,上半 Magenta→Cyan 渐变、下半镜像半透明,峰值 200ms 衰减残留;`Reduce Motion` 降为静态。
  - `WaveformView` — 整曲波形缩略(2000 桶),已播放部分填 Magenta,未播放灰;点击/拖拽 seek。

**Verified API facts:**
- `SpectrumFrame` = `struct SpectrumFrame: Equatable, Sendable { let bands: [Float]; let timestamp: Double }`(64 段, 0...1)。
- `PlaybackService`(@Observable @MainActor):`state: PlayerState`(track/position/duration/isPlaying)、`seek(to: Double)`、`installSpectrumHandler(_ handler: @escaping (SpectrumFrame) -> Void)`。`installSpectrumHandler` 把 handler 绑到 SpectrumTap(Task 1)。
- `WaveformCache.default.load(forTrackId: UUID) -> [Float]?`(Task 2,2000 桶 0...1)。
- `BrandColors` (RootView.swift): `.magenta`, `.cyan`, `.textSecondary`, `.surface`。
- `@Environment(PlaybackService.self)` 注入(Task 10 已用)。
- `@Environment(\.accessibilityReduceMotion) var reduceMotion`(系统环境值,SwiftUI 内置)。

**Downstream contracts:**
- 两个 View 都是纯展示组件,不持有播放真相;`SpectrumView` 需要调用方先 `playback.installSpectrumHandler` 注入(在 NowPlayingView onAppear 做,Task 5)。`SpectrumView` 用 `@State` 存最新帧 + `@State peaks` 存衰减峰值。
- `WaveformView` 读 `playback.state.track?.id` → `WaveformCache.default.load`(`.onAppear` + `.onChange(of: track?.id)`)。

- [ ] **Step 1: SpectrumView**

`Muses/Sources/Muses/Features/NowPlaying/SpectrumView.swift`:
```swift
import SwiftUI

struct SpectrumView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var current: SpectrumFrame?
    @State private var peaks: [Float] = [Float](repeating: 0, count: 64)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/30.0)) { timeline in
            Canvas { ctx, size in
                let bands = current?.bands ?? [Float](repeating: 0, count: 64)
                // 衰减峰值:每帧 peaks[i] = max(bands[i], peaks[i] - decay); decay 按 200ms 衰减
                if !reduceMotion {
                    let decay = Float(1.0 / (200.0 / 33.0))   // 每帧衰减量, ~200ms 归零
                    for i in 0..<64 { peaks[i] = max(bands[i], peaks[i] - decay) }
                } else {
                    for i in 0..<64 { peaks[i] = bands[i] }
                }
                drawBars(ctx: ctx, size: size, bars: peaks)
            }
        }
        .frame(height: 120)
    }

    private func drawBars(ctx: GraphicsContext, size: CGSize, bars: [Float]) {
        let n = bars.count
        let barW = size.width / CGFloat(n)
        let mid = size.height / 2
        for i in 0..<n {
            let h = CGFloat(bars[i]) * mid
            let x = CGFloat(i) * barW
            // 上半: magenta→cyan 渐变
            let topRect = CGRect(x: x, y: mid - h, width: barW * 0.8, height: h)
            let grad = LinearGradient(colors: [BrandColors.magenta, BrandColors.cyan],
                                     startPoint: .bottom, endPoint: .top)
            ctx.fill(Path(roundedRect: topRect, cornerRadius: 2), with: .linearGradient(
                grad, start: CGPoint(x: x, y: mid), end: CGPoint(x: x, y: mid - h)))
            // 下半: 镜像半透明
            let botRect = CGRect(x: x, y: mid, width: barW * 0.8, height: h)
            ctx.fill(Path(roundedRect: botRect, cornerRadius: 2),
                     with: Color(BrandColors.magenta).opacity(0.3))
        }
    }

    /// 调用方(NowPlayingView)在 onAppear 调 playback.installSpectrumHandler { current = $0 }
    func onFrame(_ f: SpectrumFrame) { current = f }
}
```

**注意:** `SpectrumView` 的 `current` 状态由调用方通过 `playback.installSpectrumHandler { frame in spectrumView.onFrame(frame) }` 推入。但 `@State` 不能从外部直接改 —— 改用方案:让 `SpectrumView` 自己持有对 `PlaybackService` 的引用(@Environment)并在 `.onAppear` 调 `installSpectrumHandler { self.current = $0 }`(闭包捕获 self 是 struct View 的 state binding,SwiftUI 用 `@State` 自动桥接)。**修订实现如下(更自洽):**
```swift
struct SpectrumView: View {
    @Environment(PlaybackService.self) private var playback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var current: SpectrumFrame?
    @State private var peaks: [Float] = [Float](repeating: 0, count: 64)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/30.0)) { _ in
            Canvas { ctx, size in
                let bands = current?.bands ?? [Float](repeating: 0, count: 64)
                if !reduceMotion {
                    let decay = Float(1.0 / 6.0)   // ~200ms 衰减(30fps, 6帧归零)
                    for i in 0..<64 { peaks[i] = max(bands[i], peaks[i] - decay) }
                } else {
                    for i in 0..<64 { peaks[i] = bands[i] }
                }
                drawBars(ctx: ctx, size: size, bars: peaks)
            }
        }
        .frame(height: 120)
        .onAppear {
            playback.installSpectrumHandler { [playback] f in
                // 闭包在 SpectrumTap 音频线程触发, 但 @State 写需主线程; 用 Task @MainActor
                Task { @MainActor in playback /* unused, just to satisfy capture */ ; current = f }
            }
        }
    }
    // drawBars 同上
}
```
**关键修正:** SpectrumTap 的 handler 在音频渲染线程调用,直接写 `@State` 不安全。用 `Task { @MainActor in current = f }` 桥到主线程(每帧一个轻量 Task,30fps 可接受;或用 `DispatchQueue.main.async`)。`reduceMotion` 时直接用当前帧不衰减。`peaks` 衰减在 Canvas 闭包里做(主线程)。

- [ ] **Step 2: WaveformView**

`Muses/Sources/Muses/Features/NowPlaying/WaveformView.swift`:
```swift
import SwiftUI

struct WaveformView: View {
    @Environment(PlaybackService.self) private var playback
    @State private var peaks: [Float] = []

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard !peaks.isEmpty else { return }
                let n = peaks.count
                let barW = size.width / CGFloat(n)
                let progress = playback.state.duration > 0
                    ? playback.state.position / playback.state.duration : 0
                let playedIdx = Int(Double(n) * progress)
                for i in 0..<n {
                    let h = CGFloat(peaks[i]) * size.height
                    let x = CGFloat(i) * barW
                    let color = i < playedIdx ? BrandColors.magenta : BrandColors.textSecondary.opacity(0.3)
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: barW * 0.7, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: color)
                }
            }
        }
        .frame(height: 60)
        .onAppear { loadPeaks() }
        .onChange(of: playback.state.track?.id) { loadPeaks() }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let ratio = Double(max(0, min(geo.size.width, v.location.x)) / geo.size.width)
                    playback.seek(to: ratio * playback.state.duration)
                }
        )
    }

    private func loadPeaks() {
        guard let id = playback.state.track?.id else { peaks = []; return }
        peaks = WaveformCache.default.load(forTrackId: id) ?? []
    }
}
```
**注意:** `DragGesture` 在 GeometryReader 外引用 geo —— 需要把 `geo` 用 `GeometryReader { geo in ... .gesture(...) }` 包好,`geo` 在闭包内可用。`.onChange(of:)` 的旧签名 `onChange(of:) { newValue in }` 或新签名 `onChange(of:) { old, new in }` 以 macOS 14 SDK 为准(14 用单参,15+ 用双参;最低部署 14 用单参 `{ _ in }` 或 `{ newValue in }`)。

- [ ] **Step 3: 构建验证**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift build`
Expected: 编译通过。Watch for:
- `Canvas` / `TimelineView` 在 macOS 14 可用(✓,14+ 引入)。
- `playback.installSpectrumHandler` 闭包跨线程 —— 确认 `Task { @MainActor in }` 编译。
- `onChange(of:)` 签名 —— 用单参 `{ _ in loadPeaks() }` 适配 macOS 14。
- `Path(roundedRect:cornerRadius:)` —— 可用。
- `Color(BrandColors.magenta)` vs `BrandColors.magenta`(已是 Color)—— 直接用 `BrandColors.magenta`。

- [ ] **Step 4: 回归**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift test`
Expected: 31 通过(无回归;本任务无新测试,UI 组件靠 build 把关)。

- [ ] **Step 5: Commit**

```bash
cd /Users/xiaotwu/Code/xyz
git add -A
git commit -m "feat: SpectrumView (mirrored bars) + WaveformView (progress overlay)"
```

---