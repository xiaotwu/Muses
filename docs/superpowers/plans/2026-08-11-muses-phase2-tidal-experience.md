# Muses 阶段 2 — TIDAL 体验层 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在阶段 1 本地播放骨架之上,补齐 TIDAL 级体验:全屏 Now Playing(巨大封面 + 唱片旋转两种模式,用户在设置里选) + 镜像条形频谱(vDSP FFT 升级) + 整曲波形缩略 + 队列抽屉(Up Next/History/拖拽/持久化恢复) + 媒体键/锁屏控件 + EQ 32 段图形编辑器 + 联网元数据补全(MusicBrainz + iTunes Search) + 设置页 + Spotlight 索引。阶段结束产出可演示的完整本地播放体验。

**Architecture:** 沿用阶段 1 分层。新增 `Services/Enrichment/` 联网补全、`Services/System/` 媒体键/Spotlight、`Features/NowPlaying/`、`Features/Queue/`、`Features/Settings/`、`Features/EQ/`。`PlaybackService` 扩展为 NowPlayingManager 的数据源,`SpectrumTap` 升级 vDSP FFT,`WaveformCache` 接入 LocalAudioEngine 预扫描。用户偏好用 `UserDefaults` + `@AppStorage` 持久化(主题/Now Playing 模式/EQ 预设),队列上下文持久化用 SwiftData 新表 `QueueState`。

**Tech Stack:** Swift 6.3 / Xcode 26.6,SwiftUI,SwiftData,AVFoundation,vDSP(Accelerate),MediaPlayer.framework(MPNowPlayingInfoCenter/MPRemoteCommandCenter),CoreSpotlight,URLSession(联网补全),macOS 14 SDK 最低部署。

## Global Constraints

- 最低部署目标:**macOS 14 (Sonoma)**,仅 **Apple Silicon (arm64)**。
- 不引入第三方依赖(阶段 2 仍不需要 Sparkle/youtube-dlp —— 阶段 3)。
- 联网元数据补全只读,无密钥:用 **MusicBrainz**(cover art archive + release-group)与 **iTunes Search API**(公开、无 token、搜 title+artist 拿封面 URL/专辑/年份)双源,Apple Music API(需 Team ID + JWT)留到阶段 4 打磨。
- 品牌色沿用阶段 1 `BrandColors`(深底 #0E0E12 / Magenta #F090F0 / Cyan #18A8F0 / Green #18A818);浅色主题留到阶段 4(阶段 2 Now Playing/频谱/队列抽屉先按深色实现,浅色对调在阶段 4)。
- 每个任务结束 commit;commit message 用 `feat:`/`test:`/`chore:`/`refactor:`/`fix:` 前缀。
- 单元测试 fixture 放 `Muses/Tests/MusesTests/Fixtures/`;联网任务用 stub `URLProtocol` 注入,不打真实网络。
- 遵守 `Reduce Motion`(频谱/唱片旋转降级为静态)。
- 不破坏阶段 1 的 26 个测试;每个 UI/服务任务后跑全量 `swift test`。

---

## File Structure

阶段 2 新建/修改文件:

```
Muses/Sources/Muses/
  Domain/
    UserPreferences.swift          @AppStorage 键定义 + NowPlayingMode/Theme 枚举(新)
    QueueState.swift               @Model 持久化队列上下文(新)
    EQPreset.swift                 @Model 自定义 EQ 预设(新)
  Services/
    Playback/
      SpectrumTap.swift            升级 vDSP FFT(改)
      LocalAudioEngine.swift       接入 WaveformCache 预扫描(改)
    Enrichment/
      MetadataEnricherService.swift  MusicBrainz + iTunes Search 联网补全(新)
      EnrichmentEndpoint.swift       URL 构造 + 限流(新)
    System/
      NowPlayingManager.swift      MPNowPlayingInfoCenter + MPRemoteCommand(新)
      SpotlightIndexer.swift      CoreSpotlight 索引 Track/Album(新)
    Queue/
      QueueService.swift           持久化/恢复 + 拖拽 API(改)
  Features/
    NowPlaying/
      NowPlayingView.swift         全屏主体 + 模式切换 + 手势(新)
      CoverArtModeView.swift       巨大封面模式(新)
      VinylModeView.swift          唱片旋转模式(新)
      SpectrumView.swift           镜像条形频谱(新)
      WaveformView.swift           整曲波形缩略 + 进度(新)
      LyricsPlaceholderView.swift  歌词区占位(阶段 3 接 LyricsService)(新)
    Queue/
      QueueDrawerView.swift        队列抽屉 + Up Next + History + 拖拽(新)
    Settings/
      SettingsView.swift           设置根(新)
      ScanRootsSettingsView.swift  Library 目录管理(新)
      AudioQualitySettingsView.swift 音质/独占(新)
      LyricsSettingsView.swift     歌词源(占位,阶段 3 实装)(新)
      ThemeSettingsView.swift      主题/Now Playing 模式(新)
      AboutView.swift              关于 + 合规声明(新)
    EQ/
      EQEditorView.swift           32 段图形编辑器 + 预设管理(新)
    PlayerBar.swift                接 Now Playing 触发 + 队列抽屉触发(改)
    RootView.swift                 接队列抽屉/Now Playing 全屏覆盖(改)
    LibraryView.swift              SongsListView 借 TrackRow(改,可选)
  App/
    MusesApp.swift                 注入 Enricher/NowPlayingManager/Spotlight(改)
Muses/Tests/MusesTests/
  SpectrumTapFFTTests.swift
  WaveformCacheIntegrationTests.swift
  MetadataEnricherServiceTests.swift
  QueueServicePersistenceTests.swift
  NowPlayingManagerTests.swift
  SpotlightIndexerTests.swift
  EQEditorViewModelTests.swift
  Phase2SmokeTests.swift
```

职责边界:
- `SpectrumTap` 仍是纯音频线程,只升级 FFT;不碰 UI。
- `MetadataEnricherService` 异步、非阻塞,命中回填 DB,`metadataStatus` 驱动 UI 平滑刷新。
- `NowPlayingManager` 只做系统桥,转发命令给 `PlaybackService`,不持有播放真相。
- `SpotlightIndexer` 响应 LibraryService 扫描完成事件,索引/去索引。
- `QueueService` 持久化在 `play()`/`next()`/`previous()`/`addToQueue()` 后自动存 `QueueState`,启动时恢复。

---

### Task 1: vDSP FFT 频谱升级

**Files:**
- Modify: `Muses/Sources/Muses/Services/Playback/SpectrumTap.swift`
- Test: `Muses/Tests/MusesTests/SpectrumTapFFTTests.swift`

**Interfaces:**
- Consumes: `Accelerate`(vDSP),`AVFoundation`
- Produces: `SpectrumTap.computeBands` 升级为 vDSP FFT(对数频段映射 64 段),`SpectrumFrame` 不变(64 段归一化 0...1)。

- [ ] **Step 1: 写失败测试**

`Muses/Tests/MusesTests/SpectrumTapFFTTests.swift`:
```swift
import Testing
import Foundation
import AVFoundation
@testable import Muses

@MainActor
@Suite("SpectrumTap FFT")
struct SpectrumTapFFTTests {
    @Test("正弦波在对应频段产生峰值")
    func sinePeakInExpectedBand() async throws {
        let sr: Double = 44100
        let freq: Double = 1000   // 1kHz
        let count = 1024
        let samples: [Float] = (0..<count).map { n in
            Float(sin(2 * .pi * freq * Double(n) / sr))
        }
        let tap = SpectrumTap()
        let bands = tap.computeBandsForTest(samples: samples, sampleRate: sr, count: 64)
        #expect(bands.count == 64)
        // 1kHz 大致落在中段(对数映射 20Hz..20kHz);峰值应在中段且高于两端
        let peakIdx = bands.firstIndex(of: bands.max() ?? 0) ?? -1
        #expect(peakIdx > 10 && peakIdx < 55)
    }

    @Test("静音输入产生全零频段")
    func silenceIsZero() {
        let samples = [Float](repeating: 0, count: 1024)
        let tap = SpectrumTap()
        let bands = tap.computeBandsForTest(samples: samples, sampleRate: 44100, count: 64)
        #expect(bands.allSatisfy { $0 < 0.01 })
    }
}
```

- [ ] **Step 2: 运行验证失败**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift test --filter SpectrumTapFFTTests`
Expected: FAIL(`computeBandsForTest` 不存在 / 仍是线性分桶)。

- [ ] **Step 3: 实现 vDSP FFT**

`SpectrumTap.swift` 升级要点(保留 NSLock 线程安全):
```swift
import Foundation
import AVFoundation
import Accelerate

final class SpectrumTap {
    // ... 既有 lock/node/handler/lastEmit ...
    private let bandCount = 64
    private let minFreq: Float = 20
    private let maxFreq: Float = 20000

    // 测试入口 + 内部共用
    func computeBandsForTest(samples: [Float], sampleRate: Double, count: Int) -> [Float] {
        computeBands(samples: samples, sampleRate: Float(sampleRate), count: count)
    }

    private func computeBands(samples: [Float], sampleRate: Float, count: Int) -> [Float] {
        // 1. Hann 窗
        let n = samples.count
        var window = [Float](repeating: 0, count: n)
        vDSP.hannWindow(&window, n, Int32(vDSP_HANN_NORM))
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))
        // 2. 实 FFT(补零到 2 的幂)
        let fftN = nextPowerOfTwo(n)
        var padded = [Float](repeating: 0, count: fftN)
        padded.withUnsafeMutableBufferPointer { buf in
            windowed.withUnsafeBufferPointer { src in
                buf.baseAddress!.update(from: src.baseAddress!, count: n)
            }
        }
        var realParts = [Float](repeating: 0, count: fftN/2)
        var imagParts = [Float](repeating: 0, count: fftN/2)
        var setup = vDSP.FFT(log2n: vDSP_Length(fftN.radix2Log2)!, radix: .radix2, ofType: .split)!
        var split = DSPSplitComplex(realp: &realParts, imagp: &imagParts)
        // vDSP FFT 详见实现;此处为骨架
        // 3. 幅度谱 → 64 对数频段聚合(20Hz..20kHz),归一化
        // 4. 返回 [Float] count 个
        ...
    }
}
```
注:`vDSP.FFT(log2n:radix:ofType:)` 在 macOS 14 SDK 可用;若 `radix2Log2` 属性名差异,以 SDK 实际为准。对数频段映射:对每个段取 `[minFreq * (maxFreq/minFreq)^(i/count), ...]` 边界,聚合该区间内的幅度均值,再 `sqrt` / 归一化到 0...1。

- [ ] **Step 4: 运行验证通过**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift test --filter SpectrumTapFFTTests`
Expected: PASS。

- [ ] **Step 5: 全量回归**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift test`
Expected: 26 既有 + 2 新 = 28 通过。

- [ ] **Step 6: Commit**

```bash
cd /Users/xiaotwu/Code/xyz
git add -A
git commit -m "feat: SpectrumTap vDSP FFT with logarithmic 64-band mapping"
```

---

### Task 2: 整曲波形预扫描 + WaveformCache 集成

**Files:**
- Modify: `Muses/Sources/Muses/Services/Playback/LocalAudioEngine.swift`
- Test: `Muses/Tests/MusesTests/WaveformCacheIntegrationTests.swift`

**Interfaces:**
- Consumes: `WaveformCache.default`, `AVAudioFile`
- Produces: `LocalAudioEngine.load(_:)` 在首次加载时后台算整曲峰值(`WaveformCache.load` 命中则跳过);`WaveformCache` 已存在(Task 1 of Phase 1 infra),本任务只接引擎 + 测。

- [ ] **Step 1: 写失败测试**

`Muses/Tests/MusesTests/WaveformCacheIntegrationTests.swift`:
```swift
import Testing
import Foundation
@testable import Muses

@MainActor
@Suite("WaveformCache Integration")
struct WaveformCacheIntegrationTests {
    @Test("load 后波形缓存命中")
    func waveformCachedAfterLoad() async throws {
        let wav = FileManager.default.temporaryDirectory.appending(path: "muses-wave-\(UUID().uuidString).wav")
        try makeSilentWav(at: wav, seconds: 1)
        let snap = TrackSnapshot(id: UUID(), title: "t", artist: "a", albumTitle: nil,
                                 durationSeconds: 1, filePath: wav.path, youTubeId: nil,
                                 artworkHash: nil, artworkUrl: nil, sampleRate: 44100,
                                 bitDepth: 16, codec: "pcm", isLossless: false)
        let engine = LocalAudioEngine()
        try await engine.load(snap)
        let peaks = WaveformCache.default.load(forTrackId: snap.id)
        #expect(peaks != nil)
        #expect((peaks?.count ?? 0) > 0)
    }
}
```

- [ ] **Step 2: 运行验证失败**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift test --filter WaveformCacheIntegrationTests`
Expected: FAIL(load 后无缓存)。

- [ ] **Step 3: 实现预扫描**

`LocalAudioEngine.load(_:)` 末尾(成功 scheduleFile 后),后台 Task:
```swift
if WaveformCache.default.load(forTrackId: track.id) == nil {
    Task.detached(priority: .utility) { [file = currentFile] in
        guard let file else { return }
        let peaks = await Self.computeWaveformPeaks(file: file, buckets: 2000)
        try? WaveformCache.default.save(peaks, forTrackId: track.id)
    }
}
```
`computeWaveformPeaks(file:buckets:)`:读 `file.length` 帧,按 buckets 分段,每段取 `max(abs(sample))`,返回 `[Float]`(0...1 归一化)。用 `AVAudioFile.read` 分块读 PCM 到 `[Float]`(单声道混合)。

- [ ] **Step 4: 运行验证通过 + 回归**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift test`
Expected: 29 通过。

- [ ] **Step 5: Commit**

```bash
cd /Users/xiaotwu/Code/xyz
git add -A
git commit -m "feat: LocalAudioEngine precomputes waveform peaks into WaveformCache"
```

---

### Task 3: SpectrumView + WaveformView 组件

**Files:**
- Create: `Muses/Sources/Muses/Features/NowPlaying/SpectrumView.swift`
- Create: `Muses/Sources/Muses/Features/NowPlaying/WaveformView.swift`

**Interfaces:**
- Consumes: `SpectrumFrame`、`PlaybackService.state.position/duration`、`WaveformCache.default`
- Produces: `SpectrumView`(镜像条形频谱,上半 Magenta→Cyan、下半镜像半透明,峰值 200ms 衰减);`WaveformView`(整曲波形缩略 + 已播放部分填 Magenta)。

- [ ] **Step 1: SpectrumView**

镜像条形:`ForEach(0..<64)`,每段两个 `Capsule`(上 `BrandColors.magenta→cyan` 渐变,下镜像 `opacity 0.3`),高度由 `bands[i]` 驱动。峰值保留:用 `@State [Float] peaks`,每帧 `peaks[i] = max(bands[i], peaks[i] - decay)`,decay 按 200ms 衰减。`TimelineView(.animation)` 推进衰减。`Reduce Motion` 降为静态(只读当前帧不衰减动画)。

- [ ] **Step 2: WaveformView**

`GeometryReader` 取宽,`ForEach(peaks)` 画竖条(已播放 `position/duration` 比例左侧填 Magenta,右侧灰 `BrandColors.textSecondary.opacity(0.3)`)。peaks 来自 `WaveformCache.default.load(forTrackId: track.id)`(load 失败画空)。点击/拖拽 seek:`onTapGesture` / `DragGesture` 映射 x→time 调 `playback.seek`。

- [ ] **Step 3: 构建验证**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift build`
Expected: 编译通过。

- [ ] **Step 4: 回归**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift test`
Expected: 29 通过(无回归)。

- [ ] **Step 5: Commit**

```bash
cd /Users/xiaotwu/Code/xyz
git add -A
git commit -m "feat: SpectrumView (mirrored bars) + WaveformView (progress overlay)"
```

---

### Task 4: UserPreferences + NowPlayingMode + 持久化

**Files:**
- Create: `Muses/Sources/Muses/Domain/UserPreferences.swift`

**Interfaces:**
- Produces: `enum NowPlayingMode { case cover, vinyl }`、`enum AppTheme { case dark, light, system }`(留用,阶段 2 默认 dark);`@AppStorage` 键常量(`muses.nowPlayingMode`、`muses.theme`、`muses.eq.activePresetId`、`muses.lyrics.source`、`muses.audio.quality`)。

- [ ] **Step 1: 实现**

```swift
import Foundation

enum NowPlayingMode: String, CaseIterable, Codable {
    case cover   // 巨大封面
    case vinyl   // 唱片旋转
}

enum AppTheme: String, CaseIterable, Codable {
    case dark, light, system
}

enum PrefKey {
    static let nowPlayingMode = "muses.nowPlayingMode"
    static let theme = "muses.theme"
    static let eqActivePresetId = "muses.eq.activePresetId"
    static let lyricsSource = "muses.lyrics.source"
    static let audioQuality = "muses.audio.quality"
}
```
注:`@AppStorage` 在 SwiftUI View 里直接用 `@AppStorage(PrefKey.nowPlayingMode) private var mode: NowPlayingMode = .cover`(需 `RawRepresentable` + `Codable`,SwiftUI 支持 `RawRepresentable` AppStorage)。若 `@AppStorage` 不直接支持自定义枚举,提供 `RawRepresentable` 扩展或用 String 中转。

- [ ] **Step 2: 构建验证**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift build`
Expected: 编译通过。

- [ ] **Step 3: Commit**

```bash
cd /Users/xiaotwu/Code/xyz
git add -A
git commit -m "feat: UserPreferences (NowPlayingMode/AppTheme/PrefKey @AppStorage)"
```

---

### Task 5: NowPlayingView 主体(巨大封面模式)

**Files:**
- Create: `Muses/Sources/Muses/Features/NowPlaying/NowPlayingView.swift`
- Create: `Muses/Sources/Muses/Features/NowPlaying/CoverArtModeView.swift`
- Create: `Muses/Sources/Muses/Features/NowPlaying/LyricsPlaceholderView.swift`
- Modify: `Muses/Sources/Muses/Features/PlayerBar.swift`(封面点击触发)
- Modify: `Muses/Sources/Muses/App/RootView.swift`(全屏覆盖)

**Interfaces:**
- Consumes: `PlaybackService`、`@AppStorage(PrefKey.nowPlayingMode)`、`SpectrumView`、`WaveformView`、`AlbumArtworkExtractor`、`BrandColors`
- Produces: `NowPlayingView`(全屏覆盖,渐变背景 + 模式切换 + 标题/音质 + 进度 + 频谱 + 波形 + 歌词占位 + 手势);`CoverArtModeView`;`LyricsPlaceholderView`。

- [ ] **Step 1: NowPlayingView 骨架**

`ZStack`:渐变背景(从封面主色 `AlbumArtworkExtractor.dominantColors` + 深色罩,`onAppear`/track 变化重算)→ 顶部工具栏(✕ 收起 / NOW PLAYING / 播放暂停)→ 中间按 `mode` 切 `CoverArtModeView` / `VinylModeView`(Task 6)→ 下方 `SpectrumView` + `WaveformView` → 标题/Artist·Album/音质徽标 → 进度条(复用 PlayerBar 的 seek Slider 逻辑)→ `LyricsPlaceholderView`(三行占位,"无可用歌词,点此搜索" — 阶段 3 接 LyricsService)。

- [ ] **Step 2: CoverArtModeView**

静止大圆角封面(480×480,居中,`shadow(radius 24)`),`matchedGeometryEffect(id: "nowPlayingArtwork", in: ns)` 从 PlayerBar 封面过渡。

- [ ] **Step 3: PlayerBar 触发 + RootView 覆盖**

PlayerBar 封面 `.onTapGesture { showNowPlaying = true }`;RootView 加 `@AppStorage` 或 `@State showNowPlaying`,`.fullScreenCover(isPresented:)` 或自定义 `.overlay` 全屏 NowPlayingView。用 `matchedGeometryEffect` 命名空间 `@Namespace`。

- [ ] **Step 4: 手势**

左右拖拽 seek(`DragGesture` 水平 → `playback.seek`);空格播放/暂停(`onKeyPress(.space)`);上滑展开队列抽屉(Task 7,先留 `onSwipeUp` 占位调 `showQueue`)。`Reduce Motion` 关闭封面交叉淡入。

- [ ] **Step 5: 构建验证 + 回归**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift build && swift test`
Expected: 编译通过,29 通过。

- [ ] **Step 6: Commit**

```bash
cd /Users/xiaotwu/Code/xyz
git add -A
git commit -m "feat: NowPlayingView full-screen (cover mode + spectrum + waveform + gestures)"
```

---

### Task 6: 唱片旋转模式 + matchedGeometryEffect 过渡

**Files:**
- Create: `Muses/Sources/Muses/Features/NowPlaying/VinylModeView.swift`
- Modify: `Muses/Sources/Muses/Features/NowPlaying/NowPlayingView.swift`(模式切换)
- Modify: `Muses/Sources/Muses/Features/Settings/ThemeSettingsView.swift`(先建,放 NowPlayingMode 切换)

**Interfaces:**
- Produces: `VinylModeView`(圆形封面 + 中心唱片孔 + 播放时旋转,暂停停);`ThemeSettingsView`(NowPlayingMode Picker + 主题占位)。

- [ ] **Step 1: VinylModeView**

圆形封面(`ClipShape(Circle())`,中心 `Circle().fill(.black).frame(width:60)` 唱片孔 + 中心 `Circle().fill(BrandColors.magenta).frame(width:8)`)。旋转:`@State angle: Angle`,`TimelineView(.animation)` 中 `angle.degrees += playback.state.isPlaying ? delta : 0`(按 `Date.timeIntervalSince` 累积,33⅓ rpm = 360°/1.8s)。`Reduce Motion` 静态(`angle = 0`)。

- [ ] **Step 2: NowPlayingView 模式切换**

按 `@AppStorage(PrefKey.nowPlayingMode) NowPlayingMode` 切换;模式改变时 `matchedGeometryEffect` 平滑(同 namespace)。

- [ ] **Step 3: ThemeSettingsView**

`Picker("Now Playing", selection: $mode) { Text("巨大封面").tag(NowPlayingMode.cover); Text("唱片旋转").tag(NowPlayingMode.vinyl) }`。主题 Picker(深色/浅色/跟随系统,阶段 2 仅 dark 实际生效,light/system 留待阶段 4)。

- [ ] **Step 4: 构建验证 + 回归**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift build && swift test`
Expected: 编译通过,29 通过。

- [ ] **Step 5: Commit**

```bash
cd /Users/xiaotwu/Code/xyz
git add -A
git commit -m "feat: VinylModeView (rotating disc) + ThemeSettingsView (NowPlayingMode switch)"
```

---

### Task 7: 队列抽屉 + 持久化恢复

**Files:**
- Create: `Muses/Sources/Muses/Domain/QueueState.swift`(@Model 持久化)
- Modify: `Muses/Sources/Muses/Services/Queue/QueueService.swift`(持久化/恢复 + 拖拽 API)
- Create: `Muses/Sources/Muses/Features/Queue/QueueDrawerView.swift`
- Modify: `Muses/Sources/Muses/App/RootView.swift`(抽屉覆盖)
- Modify: `Muses/Sources/Muses/Features/PlayerBar.swift`(队列按钮触发)
- Test: `Muses/Tests/MusesTests/QueueServicePersistenceTests.swift`

**Interfaces:**
- Consumes: `ModelContext`、`QueueItem`、`TrackSnapshot`
- Produces: `QueueState`(@Model:items JSON、currentIndex、upNext JSON、history JSON、repeatMode、shuffle、savedAt);`QueueService` 加 `persist(into:)`/`restore(from:)`/`move(from:to:)`/`moveUpNext(from:to:)`;`QueueDrawerView`(抽屉 + 上下文列表 + Up Next + History + 拖拽)。

- [ ] **Step 1: QueueState 模型**

```swift
@Model final class QueueState {
    @Attribute(.unique) var id: UUID
    var itemsJSON: String      // [QueueItem] 编码
    var currentIndex: Int
    var upNextJSON: String
    var historyJSON: String
    var repeatModeRaw: String
    var shuffle: Bool
    var savedAt: Date
    init(...) { ... }
}
```
`QueueItem` 需 `Codable`(已 `Sendable`,补 `Codable`)。

- [ ] **Step 2: QueueService 持久化**

`play()`/`next()`/`previous()`/`playNext()`/`addToQueue()`/`setRepeat()`/`toggleShuffle()` 后调 `persist(into: ModelContext)`(upsert 单行 QueueState,id 固定 = 单机单队列)。`restore(from:)` 解码回填。`move(from:to:)`/`moveUpNext(from:to:)` 支持拖拽(`.onMove`)。

- [ ] **Step 3: QueueDrawerView**

`.overlay(alignment: .trailing)` 滑入抽屉(宽 360),`List` 三 Section:当前队列(`.onMove`)、Up Next(`.onMove`)、History(只读)。每行 TrackRow 复用。`@State showQueue` 驱动 `.offset` 动画。

- [ ] **Step 4: 写持久化测试**

`QueueServicePersistenceTests`:`play` → persist → 新 QueueService `restore` → 断言 items/currentIndex/upNext 一致;`move` 后顺序变化。

- [ ] **Step 5: 构建验证 + 回归**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift build && swift test`
Expected: 编译通过,29 + 持久化测试通过。

- [ ] **Step 6: Commit**

```bash
cd /Users/xiaotwu/Code/xyz
git add -A
git commit -m "feat: QueueDrawerView + QueueState persistence/restore + drag reorder"
```

---

### Task 8: NowPlayingManager(媒体键 + 锁屏控件)

**Files:**
- Create: `Muses/Sources/Muses/Services/System/NowPlayingManager.swift`
- Modify: `Muses/Sources/Muses/App/MusesApp.swift`(注入 + 启动)
- Modify: `Muses/Sources/Muses/Services/Playback/PlaybackService.swift`(暴露 state 变化给 manager)
- Test: `Muses/Tests/MusesTests/NowPlayingManagerTests.swift`

**Interfaces:**
- Consumes: `MediaPlayer.framework`(MPNowPlayingInfoCenter/MPRemoteCommandCenter)、`PlaybackService`、`ArtworkCache`
- Produces: `NowPlayingManager`(@MainActor):订阅 `playback.state` 变化 → 更新 `nowPlayingInfo`(title/artist/album/artwork/duration/elapsedTime/playbackRate);绑定 `MPRemoteCommandCenter` 的 play/pause/next/prev/seekForward/seekBackward/changePlaybackPosition 转发 `PlaybackService`。

- [ ] **Step 1: NowPlayingManager**

```swift
import MediaPlayer
@MainActor final class NowPlayingManager {
    let playback: PlaybackService
    init(_ playback: PlaybackService) { self.playback = playback; bindCommands(); observeState() }
    private func updateInfo() { /* MPNowPlayingInfoCenter.default().nowPlayingInfo = [...] */ }
    private func bindCommands() { /* MPRemoteCommandCenter.shared().playCommand.addTarget { ... } */ }
}
```
artwork:`MPMediaItemArtwork(boundsSize:image:)` 从 `ArtworkCache.default.data(forHash:)` → `NSImage`。

- [ ] **Step 2: PlaybackService 钩子**

`PlaybackService` 在 `load(_:)`/`toggle()`/`seek` 后 `state` 已变;`NowPlayingManager` 用 `Combine` 或 `@Observable` 轮询(Phase 1 的 completion observer 已有 300ms 轮询,manager 可独立 250ms 轮询 `state` 更新 `elapsedTime`,或用 `withObservationTracking`)。

- [ ] **Step 3: 测试**

`NowPlayingManagerTests`:mock `PlaybackService`(用真实 LocalAudioEngine + QueueService + 静音 WAV)→ load 后断言 `MPNowPlayingInfoCenter.default().nowPlayingInfo?["MPMediaItemPropertyTitle"] == "t"`;命令回调触发 `playback.toggle()`。

- [ ] **Step 4: MusesApp 注入**

`init()` 末尾 `NowPlayingManager(playbackService)` 存为属性防止释放。

- [ ] **Step 5: 构建验证 + 回归**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift build && swift test`
Expected: 编译通过,无回归。

- [ ] **Step 6: Commit**

```bash
cd /Users/xiaotwu/Code/xyz
git add -A
git commit -m "feat: NowPlayingManager (MPNowPlayingInfoCenter + remote commands)"
```

---

### Task 9: EQ 32 段图形编辑器 + 预设管理

**Files:**
- Create: `Muses/Sources/Muses/Domain/EQPreset.swift`(@Model 自定义预设)
- Create: `Muses/Sources/Muses/Features/EQ/EQEditorView.swift`
- Test: `Muses/Tests/MusesTests/EQEditorViewModelTests.swift`

**Interfaces:**
- Consumes: `EQBand`、`EQPresets`、`PlaybackService.setEQ(_:)`、`@AppStorage(PrefKey.eqActivePresetId)`
- Produces: `EQEditorView`(32 段图形编辑器:频率/增益/Q 滑杆 + 拖拽曲线;预设列表(Flat/HiFi/Bass Boost/Vocal 内置 + 自定义保存/删除));`EQPreset`(@Model:id/name/bandsJSON/createdAt)。

- [ ] **Step 1: EQPreset 模型**

`@Model final class EQPreset { id, name, bandsJSON, createdAt }`,内置预设不存 DB(用 `EQPresets` enum 静态),自定义存 DB。

- [ ] **Step 2: EQEditorView**

`GeometryReader` 画 32 竖条滑杆(增益 -24...24 dB,频率对数刻度 20Hz..20kHz),拖拽点改 `bands[i].gain`。曲线连接:`Path` 平滑插值。预设 Picker:内置 + `@Query EQPreset`。保存:输入名 → 存 `EQPreset` + 设 activePresetId。`onChange` of bands → `playback.setEQ(bands)`。

- [ ] **Step 3: 测试**

`EQEditorViewModelTests`:改 band → `playback.engine` 的 EQ band gain 更新(mock 检查 `AVAudioUnitEQ.bands[i].gain`);保存预设 → `@Query` 命中;删除 → 不命中。

- [ ] **Step 4: 构建验证 + 回归**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift build && swift test`
Expected: 编译通过,无回归。

- [ ] **Step 5: Commit**

```bash
cd /Users/xiaotwu/Code/xyz
git add -A
git commit -m "feat: EQEditorView (32-band graphic editor + preset management)"
```

---

### Task 10: 联网元数据补全(MusicBrainz + iTunes Search)

**Files:**
- Create: `Muses/Sources/Muses/Services/Enrichment/MetadataEnricherService.swift`
- Create: `Muses/Sources/Muses/Services/Enrichment/EnrichmentEndpoint.swift`
- Modify: `Muses/Sources/Munes/Services/Library/LibraryService.swift`(扫描后入待补全队列)
- Modify: `Muses/Sources/Muses/Domain/Track.swift`(`metadataStatus` 已有,补 `artworkUrl` 回填)
- Test: `Muses/Tests/MusesTests/MetadataEnricherServiceTests.swift`

**Interfaces:**
- Consumes: `URLSession`、`ArtworkCache.default`、`Track`、`MetadataStatus`
- Produces: `MetadataEnricherService`(@MainActor):`enrich(_ track: Track) async` — 先 iTunes Search(`https://itunes.apple.com/search?term=<title+artist>&entity=song&limit=5`)拿 `artworkUrl`(升级到 600x600)+ albumTitle + year;未命中兜底 MusicBrainz(`https://musicbrainz.org/ws/2/release-group/?query=<title+artist>&fmt=json`)→ cover art archive(`https://coverartarchive.org/release/<mbid>/front`)。命中回填 `artworkUrl`/`albumTitle`/`year`,`metadataStatus = .complete`;未命中 `.missing`。限流:MusicBrainz 要求 1 req/sec(用户 agent header)。

- [ ] **Step 1: EnrichmentEndpoint + stub URLProtocol 测试**

测试用 `URLProtocol` stub 返回 iTunes/Search JSON fixture,不打真实网络。断言 `artworkUrl` 升级(`100x100` → `600x600`)、`albumTitle` 回填、限流 sleep。

- [ ] **Step 2: MetadataEnricherService**

```swift
@MainActor final class MetadataEnricherService {
    let session: URLSession
    let artworkCache: ArtworkCache
    let container: ModelContext
    func enrich(_ track: Track) async { /* iTunes → MB → 回填 */ }
}
```
artwork URL 下载到 `ArtworkCache` 存 hash,回填 `localArtworkHash`(统一走封面墙)。iTunes `artworkUrl` 替换 `100x100bb` → `600x600bb`。

- [ ] **Step 3: LibraryService 接入**

扫描完成(`scan(root:)` 末尾)后,对 `metadataStatus == .embedded` 且缺 `artworkHash`/`albumTitle` 的 Track 入 enrich 队列,`Task` 并发限 4 调 `enricher.enrich`。UI 通过 `@Query` 自动看到封面墙刷新。

- [ ] **Step 4: 测试 + 回归**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift test --filter MetadataEnricherServiceTests && swift test`
Expected: 新测试 + 既有全绿。

- [ ] **Step 5: Commit**

```bash
cd /Users/xiaotwu/Code/xyz
git add -A
git commit -m "feat: MetadataEnricherService (iTunes Search + MusicBrainz) artwork/album/year backfill"
```

---

### Task 11: SettingsView 设置页

**Files:**
- Create: `Muses/Sources/Muses/Features/Settings/SettingsView.swift`
- Create: `Muses/Sources/Muses/Features/Settings/ScanRootsSettingsView.swift`
- Create: `Muses/Sources/Muses/Features/Settings/AudioQualitySettingsView.swift`
- Create: `Muses/Sources/Muses/Features/Settings/LyricsSettingsView.swift`
- Create: `Muses/Sources/Muses/Features/Settings/AboutView.swift`
- Modify: `Muses/Sources/Muses/Features/RootView.swift`(Settings section 路由)
- Modify: `Muses/Sources/Muses/Features/SidebarView.swift`(已有点击)

**Interfaces:**
- Produces: `SettingsView`(`Form`:Library(ScanRoots 列表 + 重新扫描 + 清理不可用)/ 音质(native/独占占位、YouTube bestaudio/省流占位)/ EQ(入口 → EQEditorView sheet)/ 歌词(源 Picker 占位)/ 主题(ThemeSettingsView 复用)/ 关于(AboutView 版本 + logo + 合规声明))。

- [ ] **Step 1: ScanRootsSettingsView**

`@Query ScanRoot` 列表,增删,`watch` Toggle,重新扫描按钮调 `library.rescan()`,清理不可用调 `library.purgeUnavailable()`。

- [ ] **Step 2: AudioQualitySettingsView / LyricsSettingsView / AboutView**

音质 `@AppStorage(PrefKey.audioQuality)`;歌词源 `@AppStorage(PrefKey.lyricsSource)`(占位,阶段 3 实装);About 显示版本(读 `Bundle.main.infoDictionary`)、logo、合规声明("个人使用,非 App Store,YouTube 内容受 YT ToS 约束")。

- [ ] **Step 3: SettingsView 组装 + 路由**

RootView `case .settings: SettingsView()`。Sidebar 已有 Settings 入口。

- [ ] **Step 4: 构建验证 + 回归**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift build && swift test`
Expected: 编译通过,无回归。

- [ ] **Step 5: Commit**

```bash
cd /Users/xiaotwu/Code/xyz
git add -A
git commit -m "feat: SettingsView (ScanRoots/audio/lyrics/theme/about)"
```

---

### Task 12: Spotlight 索引 + NSUserActivity

**Files:**
- Create: `Muses/Sources/Muses/Services/System/SpotlightIndexer.swift`
- Modify: `Muses/Sources/Muses/App/MusesApp.swift`(启动恢复 + 索引监听)
- Test: `Muses/Tests/MusesTests/SpotlightIndexerTests.swift`

**Interfaces:**
- Consumes: `CoreSpotlight`、`LibraryService`、`Track`/`Album`
- Produces: `SpotlightIndexer`:扫描完成后索引 Track/Album(`CSSearchableItem`:title/artist/album/artwork/`play:` deep link),删除时去索引。`NSUserActivity`(持续播放,记录 `currentIndex`)用于 app 重启恢复队列(配合 Task 7 的 QueueState 恢复)。

- [ ] **Step 1: SpotlightIndexer**

```swift
import CoreSpotlight
@MainActor final class SpotlightIndexer {
    func index(_ tracks: [Track], _ albums: [Album]) { /* CSSearchableIndex.default().indexSearchableItems */ }
    func deindex(_ ids: [UUID]) { /* deleteSearchableItems */ }
}
```
deep link:`muses://play?trackId=<id>`(阶段 2 只索引,URL Scheme 处理在 `.onOpenURL` 留占位,阶段 3 完善)。

- [ ] **Step 2: 测试**

`SpotlightIndexerTests`:index 后 `CSSearchableIndex.default()` 查询命中(用 `indexSearchableItems` mock 或实际索引后 `fetch`);deindex 后不命中。

- [ ] **Step 3: 构建验证 + 回归**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift build && swift test`
Expected: 编译通过,无回归。

- [ ] **Step 4: Commit**

```bash
cd /Users/xiaotwu/Code/xyz
git add -A
git commit -m "feat: SpotlightIndexer (Track/Album indexing) + NSUserActivity"
```

---

### Task 13: 阶段 2 集成验收冒烟

**Files:**
- Create: `Muses/Tests/MusesTests/Phase2SmokeTests.swift`

**Interfaces:**
- Consumes: 阶段 2 全部服务

- [ ] **Step 1: 写端到端冒烟测试**

`Phase2SmokeTests`:`scan → enrich(stub 网络)→ play → spectrum frame 产出 → waveform 缓存命中 → queue persist → restore → next → EQ setEQ 生效 → NowPlayingManager info 更新`。用 stub URLProtocol 避免真实网络。

- [ ] **Step 2: 运行全部测试**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift test`
Expected: 全部 PASS(阶段 1 + 阶段 2)。

- [ ] **Step 3: 人工 e2e 冒烟(可选,GUI)**

Run: `cd /Users/xiaotwu/Code/xyz && swift run`
验收清单:
- 播放曲目 → 点 PlayerBar 封面 → Now Playing 全屏放大过渡。
- 频谱条镜像跳动,波形进度推进,拖波形 seek。
- 设置里切"唱片旋转" → 封面变圆形旋转,暂停停。
- 队列按钮 → 抽屉滑入,拖拽 Up Next 重排,重启 app 队列恢复。
- 媒体键 F8/F9/F10/F11 播放/暂停/上下首;锁屏/控制中心显示曲目。
- EQ 编辑器改增益实时生效。
- 扫描缺封面目录 → 联网补全后封面墙刷新(若联网可用)。
- Spotlight 搜专辑名 → 可点播放。

- [ ] **Step 4: Commit**

```bash
cd /Users/xiaotwu/Code/xyz
git add -A
git commit -m "test: phase 2 end-to-end smoke (scan→enrich→play→spectrum→queue→eq→nowplaying)"
```

---

## 阶段 2 完成定义

- [ ] 所有 13 任务 commit 完成。
- [ ] `swift test` 全绿(阶段 1 + 阶段 2 全部)。
- [ ] `swift run` 可人工演示完整 TIDAL 体验层(Now Playing 双模式 + 频谱/波形 + 队列抽屉持久化 + 媒体键 + EQ + 联网补全 + 设置 + Spotlight)。
- [ ] git log 有清晰 feat/test/chore 提交序列。
- [ ] 不破坏阶段 1 任何测试。

阶段 3(在线与同步:yt-dlp/YouTubeStreamEngine/YouTubeImportsView/LyricsService/Sparkle)将在本计划验收后作为独立后续计划编写。阶段 4(主题深浅/性能/快照/合规)同理。

---

## 阶段 2 决策记录(执行中沿用)

- **联网元数据源**:MusicBrainz + iTunes Search API(均免费无 token);Apple Music API(需 Team ID + JWT)留到阶段 4 打磨,避免个人分发密钥管理负担。
- **Now Playing 双模式**:巨大封面 + 唱片旋转两种全做,设置里 `NowPlayingMode` 切换(用户明确要求)。
- **频谱 FFT**:升级 vDSP FFT 对数 64 段(spec §6.2 明确要求,用户偏好"越全越好")。
- **浅色主题**:阶段 2 仅实现深色路径;`AppTheme` 枚举预留,浅色对调在阶段 4。
- **Apple Music API**:不做(阶段 2)。
- **Sparkle/youtube-dlp**:不做(阶段 3)。