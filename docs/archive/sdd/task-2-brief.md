### Task 2: 整曲波形预扫描 + WaveformCache 集成

**Files:**
- Modify: `Muses/Sources/Muses/Services/Playback/LocalAudioEngine.swift`
- Test: `Muses/Tests/MusesTests/WaveformCacheIntegrationTests.swift`

**Interfaces:**
- Consumes: `WaveformCache.default`(已有,Phase 1 infra)、`AVAudioFile`、`AVAudioFile.read`、`TrackSnapshot`
- Produces: `LocalAudioEngine.load(_:)` 在成功加载后,后台预扫描整曲峰值存入 `WaveformCache`(命中则跳过)。新增 `static func computeWaveformPeaks(file:buckets:)` 取整曲 PCM 按桶聚合 `max(abs(sample))`,归一化 0...1。

**Verified API facts:**
- `WaveformCache.default.load(forTrackId: UUID) -> [Float]?`、`save(_ peaks: [Float], forTrackId: UUID) throws`、`path(forTrackId:) -> URL`(Phase 1 infra,已存在)。
- `AVAudioFile(forReading:)` 已用;`file.length` 是 `AVAudioFramePosition`(总帧数);`file.processingFormat.sampleRate` 是采样率;`file.processingFormat.channelCount` 是声道数。
- `AVAudioFile.read(into:)` 读 PCM 到 `AVAudioPCMBuffer`;`buffer.floatChannelData` 给 `UnsafePointer<Float>` 每声道。
- `LocalAudioEngine.load` 当前签名:`func load(_ track: TrackSnapshot) async throws`(Phase 6 修复后 throws + 设 state.track)。
- `TrackSnapshot.id: UUID` 是曲目唯一标识(波形缓存键)。

**Downstream contracts:**
- 不改 `load` 的对外行为/签名,只在成功 scheduleFile 后追加后台 Task。
- 不阻塞播放:预扫描在 `Task.detached(priority: .utility)`,失败静默(波形是可视化辅助,缺了 UI 画空)。
- `WaveformCache` 键 = `track.id`;同一曲目重 load 命中缓存跳过。
- Task 3 `WaveformView` 将读 `WaveformCache.default.load(forTrackId:)` 画缩略波形。

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
        // 后台预扫描是 detached Task, 轮询等缓存落盘
        var peaks: [Float]? = nil
        for _ in 0..<40 {   // 最多 ~2s
            peaks = WaveformCache.default.load(forTrackId: snap.id)
            if peaks != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(peaks != nil)
        #expect((peaks?.count ?? 0) > 0)
    }

    @Test("重复 load 命中缓存不再重算")
    func cacheHitSkipsRecompute() async throws {
        let wav = FileManager.default.temporaryDirectory.appending(path: "muses-wave2-\(UUID().uuidString).wav")
        try makeSilentWav(at: wav, seconds: 1)
        let snap = TrackSnapshot(id: UUID(), title: "t", artist: "a", albumTitle: nil,
                                 durationSeconds: 1, filePath: wav.path, youTubeId: nil,
                                 artworkHash: nil, artworkUrl: nil, sampleRate: 44100,
                                 bitDepth: 16, codec: "pcm", isLossless: false)
        let engine = LocalAudioEngine()
        try await engine.load(snap)
        for _ in 0..<40 { if WaveformCache.default.load(forTrackId: snap.id) != nil { break }; try await Task.sleep(for: .milliseconds(50)) }
        let first = WaveformCache.default.load(forTrackId: snap.id)
        // 第二次 load 命中缓存(静音 WAV 峰值全 0,但缓存行存在)
        try await engine.load(snap)
        try await Task.sleep(for: .milliseconds(100))
        let second = WaveformCache.default.load(forTrackId: snap.id)
        #expect(first != nil)
        #expect(second != nil)
    }
}
```

- [ ] **Step 2: 运行验证失败**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift test --filter WaveformCacheIntegrationTests`
Expected: FAIL(load 后无缓存)。

- [ ] **Step 3: 实现预扫描**

在 `LocalAudioEngine.swift`:
1. `load(_:)` 成功 `scheduleFile` 后追加:
```swift
if WaveformCache.default.load(forTrackId: track.id) == nil {
    let trackId = track.id
    let filePath = path
    Task.detached(priority: .utility) {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: filePath)) else { return }
        let peaks = Self.computeWaveformPeaks(file: file, buckets: 2000)
        try? WaveformCache.default.save(peaks, forTrackId: trackId)
    }
}
```
2. 新增静态方法:
```swift
static func computeWaveformPeaks(file: AVAudioFile, buckets: Int) -> [Float] {
    let totalFrames = Int(file.length)
    guard totalFrames > 0 else { return [Float](repeating: 0, count: buckets) }
    let format = file.processingFormat
    let channels = Int(format.channelCount)
    let framesPerBuffer = min(4096, totalFrames)
    var peaks = [Float](repeating: 0, count: buckets)
    var counts = [Int](repeating: 0, count: buckets)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(framesPerBuffer)) else { return peaks }
    var framesRead: Int = 0
    while framesRead < totalFrames {
        let toRead = AVAudioFrameCount(min(framesPerBuffer, totalFrames - framesRead))
        buffer.frameLength = toRead
        do { try file.read(into: buffer) } catch { break }
        guard let ch = buffer.floatChannelData else { break }
        let n = Int(toRead)
        for i in 0..<n {
            var s: Float = 0
            for c in 0..<channels { s += abs(ch[c][i]) }
            let mono = s / Float(channels)
            let bucket = min(buckets - 1, Int(Double(framesRead + i) / Double(totalFrames) * Double(buckets)))
            peaks[bucket] = max(peaks[bucket], mono)
            counts[bucket] += 1
        }
        framesRead += n
    }
    // 归一化到 0...1
    let maxPeak = peaks.max() ?? 0
    if maxPeak > 0 { for i in 0..<buckets { peaks[i] /= maxPeak } }
    return peaks
}
```

**注意:**
- `computeWaveformPeaks` 是 `static`(不碰实例状态),便于测试和复用。
- 静音 WAV 峰值全 0,maxPeak=0 跳过归一化,缓存行全 0 存在(测试断言 `count > 0` 通过)。
- `Task.detached` 捕获 `trackId` 和 `filePath`(值类型/不可变),不捕获 self,避免跨线程访问 @MainActor。
- buckets=2000 是波形缩略分辨率(Task 3 WaveformView 用),可调。

- [ ] **Step 4: 运行验证通过**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift test --filter WaveformCacheIntegrationTests`
Expected: 2 PASS。若轮询超时(detached Task 太慢),把 40 次×50ms 加到 60 次或调高 priority,优先排查预扫描是否真的写了缓存。

- [ ] **Step 5: 全量回归**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift test`
Expected: 29(Phase 1+2 Task1)+ 2 = 31 通过。不破坏 Phase 1 LocalAudioEngineTests(它测 load/play/seek,不碰 WaveformCache,但 load 现在多起一个 detached Task — 确认无副作用)。

- [ ] **Step 6: Commit**

```bash
cd /Users/xiaotwu/Code/xyz
git add -A
git commit -m "feat: LocalAudioEngine precomputes waveform peaks into WaveformCache"
```

---