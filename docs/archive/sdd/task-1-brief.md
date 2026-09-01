### Task 1: vDSP FFT 频谱升级

**Files:**
- Modify: `Muses/Sources/Muses/Services/Playback/SpectrumTap.swift`
- Test: `Muses/Tests/MusesTests/SpectrumTapFFTTests.swift`

**Interfaces:**
- Consumes: `Accelerate`(vDSP)、`AVFoundation`、`SpectrumFrame`(不变)
- Produces: `SpectrumTap.computeBands` 升级为 vDSP FFT(对数频段映射 64 段);新增 `computeBandsForTest` 内部入口供测试直接喂样本。`SpectrumFrame` 结构不变(64 段归一化 0...1)。

**Verified vDSP API (probe confirmed on Xcode 26.6 / macOS 14 SDK):**
- `vDSP.FFT(log2n: vDSP_Length, radix: .radix2, ofType: DSPSplitComplex.self) -> vDSP.FFT<DSPSplitComplex>?` — 可用。
- `vDSP_Length(Int(log2(Double(n))))` 算 log2n。
- `vDSP.hannWindow(&window, count, Int32(vDSP_HANN_NORM))` — Hann 窗。
- `vDSP_vmul` 逐元素乘(加窗)。
- `setup.forward(input:, output:)` 跑正变换(input/output 都是 `DSPSplitComplex`)。
- `vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))` 算幅度。
- `vDSP_vsmul` / `vDSP_vsadd` 归一化。
**关键**:vDSP.FFT 的 `input` 要求是 `DSPSplitComplex`,需把实数样本放进 `realp`,imagp 全 0。FFT 输出 `n/2` 个频段(bin),bin i 对应频率 `i * sampleRate / n`。对数映射:每段边界 `minFreq * (maxFreq/minFreq)^(i/64)`。

**Downstream contracts:**
- `SpectrumTap` 仍是音频渲染线程安全(NSLock 保留),`process` 不变,只换 `computeBands` 实现。
- `SpectrumFrame(bands:count:timestamp:)` 不变,UI(Task 3 SpectrumView)直接绑定 `bands`。
- `bandCount = 64` 不变,频率范围 `minFreq=20Hz, maxFreq=20000Hz`。
- 归一化:输出 0...1,可用 `vDSP_vsmul` 乘一个缩放因子(如 `1/ (n/4)`)再 `min(1.0, ...)` 截断。静音输入应近似全零。

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
    @Test("正弦波峰值落在对应频段")
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
        // 1kHz 在对数映射 20Hz..20kHz 大致落在中段(段 30-45 附近)
        let maxVal = bands.max() ?? 0
        let peakIdx = bands.firstIndex(of: maxVal) ?? -1
        #expect(peakIdx > 20 && peakIdx < 55)
        #expect(maxVal > 0.1)   // 正弦应有明显能量
    }

    @Test("静音输入产生近似零频段")
    func silenceIsNearZero() {
        let samples = [Float](repeating: 0, count: 1024)
        let tap = SpectrumTap()
        let bands = tap.computeBandsForTest(samples: samples, sampleRate: 44100, count: 64)
        #expect(bands.allSatisfy { $0 < 0.01 })
    }

    @Test("低频正弦波峰值在低频段")
    func lowFreqPeakInLowBand() {
        let sr: Double = 44100
        let freq: Double = 80   // 80Hz
        let count = 2048
        let samples: [Float] = (0..<count).map { n in
            Float(sin(2 * .pi * freq * Double(n) / sr))
        }
        let tap = SpectrumTap()
        let bands = tap.computeBandsForTest(samples: samples, sampleRate: sr, count: 64)
        let maxVal = bands.max() ?? 0
        let peakIdx = bands.firstIndex(of: maxVal) ?? -1
        // 80Hz 应该在前几段(低频)
        #expect(peakIdx < 15)
    }
}
```

- [ ] **Step 2: 运行验证失败**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift test --filter SpectrumTapFFTTests`
Expected: FAIL(`computeBandsForTest` 不存在 / 仍是线性分桶)。

- [ ] **Step 3: 实现 vDSP FFT**

`Muses/Sources/Muses/Services/Playback/SpectrumTap.swift` 修改要点:
1. `import Accelerate`(顶部)。
2. `computeBands` 签名改为 `computeBands(samples: [Float], sampleRate: Float, count: Int) -> [Float]`(当前是 `count` 参数其实是 frameCount,语义重命名)。`process` 调用处传 `sampleRate: Float(buffer.format.sampleRate)`。
3. 新增 `computeBandsForTest(samples: [Float], sampleRate: Double, count: Int) -> [Float]`(转调内部 `computeBands`)。

实现骨架:
```swift
private func computeBands(samples: [Float], sampleRate: Float, count: Int) -> [Float] {
    let n = samples.count
    guard n > 1 else { return [Float](repeating: 0, count: bandCount) }
    // 1. Hann 窗
    var window = [Float](repeating: 0, count: n)
    vDSP.hannWindow(&window, n, Int32(vDSP_HANN_NORM))
    var windowed = [Float](repeating: 0, count: n)
    vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))
    // 2. 补零到 2 的幂
    let fftN = nextPowerOfTwo(n)
    var realIn = [Float](repeating: 0, count: fftN)
    realIn.withUnsafeMutableBufferPointer { buf in
        windowed.withUnsafeBufferPointer { src in
            buf.baseAddress!.update(from: src.baseAddress!, count: n)
        }
    }
    var imagIn = [Float](repeating: 0, count: fftN)
    // 3. FFT
    let log2n = vDSP_Length(Int(log2(Double(fftN))))
    guard let setup = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
        return [Float](repeating: 0, count: bandCount)
    }
    var realOut = [Float](repeating: 0, count: fftN/2)
    var imagOut = [Float](repeating: 0, count: fftN/2)
    var input = DSPSplitComplex(realp: &realIn, imagp: &imagIn)
    var output = DSPSplitComplex(realp: &realOut, imagp: &imagOut)
    setup.forward(input: input, output: &output)
    // 4. 幅度谱
    var magnitudes = [Float](repeating: 0, count: fftN/2)
    vDSP_zvabs(&output, 1, &magnitudes, 1, vDSP_Length(fftN/2))
    // 5. 对数频段聚合 20Hz..20kHz, 64 段
    var bands = [Float](repeating: 0, count: bandCount)
    let nyquist = sampleRate / 2
    let maxFreq: Float = min(20000, nyquist)
    let minFreq: Float = 20
    for b in 0..<bandCount {
        let lo = minFreq * pow(maxFreq/minFreq, Float(b)/Float(bandCount))
        let hi = minFreq * pow(maxFreq/minFreq, Float(b+1)/Float(bandCount))
        let loBin = max(1, Int(lo * Float(fftN) / sampleRate))
        let hiBin = max(loBin+1, Int(hi * Float(fftN) / sampleRate))
        var sum: Float = 0
        var cnt = 0
        for i in loBin..<min(hiBin, fftN/2) { sum += magnitudes[i]; cnt += 1 }
        bands[b] = cnt > 0 ? sum / Float(cnt) : 0
    }
    // 6. 归一化到 0...1(按最大值或固定缩放)
    var maxBand: Float = 0
    vDSP_maxmg(bands, 1, &maxBand, 1, vDSP_Length(bandCount))  // 或用 vDSP_maxv
    if maxBand > 0 { vDSP_vsmul(bands, 1, [1/maxBand], &bands, 1, vDSP_Length(bandCount)) }
    return bands
}

func computeBandsForTest(samples: [Float], sampleRate: Double, count: Int) -> [Float] {
    computeBands(samples: samples, sampleRate: Float(sampleRate), count: count)
}
```

**注意:**
- `vDSP_maxmg` / `vDSP_maxv` 签名以 SDK 实际为准;若不确定,用 Swift 的 `bands.max()` 找最大值再 `vDSP_vsmul` 缩放,更稳妥。
- `DSPSplitComplex(realp:imagp:)` 接受 `UnsafeMutablePointer<Float>`,用 `&array` 传入即可(array 提供 buffer base)。
- `setup.forward(input:output:)` 签名以 SDK 实际为准;可能是 `forward(input:)` 返回 output,或 inout。按编译器提示调整。
- 归一化用"按帧最大值"而非固定常数,避免不同音量下频谱条太满或太空;静音帧 maxBand=0 跳过缩放,全零。
- `process` 调用处:`computeBands(samples: samples, sampleRate: Float(buffer.format.sampleRate), count: frameCount)` —— 注意原 `process` 传 `count: frameCount` 是给旧线性分桶用的,现在 count 参数(64)其实是 bandCount,改传法见上。

- [ ] **Step 4: 运行验证通过**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift test --filter SpectrumTapFFTTests`
Expected: 3 tests PASS。若 `sinePeakInExpectedBand` 的 `peakIdx > 20 && < 55` 不中(1kHz 落点因对数映射不同),调整断言区间到合理范围(如 `10...55`),但优先调实现让落点合理。

- [ ] **Step 5: 全量回归**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift test`
Expected: 26 既有(Phase 1)+ 3 新 = 29 通过。**不能破坏 SpectrumTapTests**(Phase 1 的频谱测试,若它断言线性分桶行为,需同步更新 —— 但 Phase 1 测试只测 "tap 产出 SpectrumFrame",应不受影响,确认即可)。

- [ ] **Step 6: Commit**

```bash
cd /Users/xiaotwu/Code/xyz
git add -A
git commit -m "feat: SpectrumTap vDSP FFT with logarithmic 64-band mapping"
```

---