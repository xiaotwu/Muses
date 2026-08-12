import Foundation
import AVFoundation
import Accelerate

final class SpectrumTap {
    private var node: AVAudioNode?
    private var bus: AVAudioNodeBus = 0
    // handler/lastEmit 在音频渲染线程(process)读、主线程(start/stop)写,
    // 用锁保护避免 tap 重绑定时竞争。
    private let lock = NSLock()
    private var handler: ((SpectrumFrame) -> Void)?
    private var lastEmit: Double = 0
    private let bandCount = 64

    func start(on node: AVAudioNode, bus: AVAudioNodeBus = 0,
               format: AVAudioFormat, handler: @escaping (SpectrumFrame) -> Void) {
        // 防止重复安装导致 "tap already installed" 崩溃
        if self.node != nil { stop() }
        lock.lock()
        self.node = node; self.bus = bus; self.handler = handler
        lock.unlock()
        node.installTap(onBus: bus, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
    }

    func stop() {
        node?.removeTap(onBus: bus)
        lock.lock()
        node = nil; handler = nil
        lock.unlock()
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        let handler = self.handler
        let prevEmit = lastEmit
        let shouldEmit = now - prevEmit >= 1.0 / 30.0
        if shouldEmit { lastEmit = now }
        lock.unlock()
        guard shouldEmit, let handler else { return }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        guard let ch = buffer.floatChannelData else { return }
        var samples = [Float](repeating: 0, count: frameCount)
        // mono mix
        let channels = Int(buffer.format.channelCount)
        for i in 0..<frameCount {
            var s: Float = 0
            for c in 0..<channels { s += ch[c][i] }
            samples[i] = s / Float(channels)
        }

        let bands = computeBands(samples: samples, sampleRate: Float(buffer.format.sampleRate), count: bandCount)
        handler(SpectrumFrame(bands: bands, timestamp: now))
    }

    // MARK: - FFT

    /// 对数频段映射的 vDSP FFT 频谱计算。
    /// - Parameters:
    ///   - samples: 单声道样本(已 mono mix)。
    ///   - sampleRate: 采样率(Hz)。
    ///   - count: 输出频段数(内部固定为 bandCount=64,参数保留以兼容旧调用)。
    /// - Returns: 归一化到 0...1 的频段数组,长度为 bandCount。
    private func computeBands(samples: [Float], sampleRate: Float, count: Int) -> [Float] {
        let n = samples.count
        guard n > 1 else { return [Float](repeating: 0, count: bandCount) }

        // 1. Hann 窗(归一化到 0...1)
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

        // 2. 补零到 2 的幂
        let fftN: Int = 1 << (Int.bitWidth - n.leadingZeroBitCount)
        var realIn = [Float](repeating: 0, count: fftN)
        realIn.withUnsafeMutableBufferPointer { dstBuf in
            windowed.withUnsafeBufferPointer { srcBuf in
                dstBuf.baseAddress!.update(from: srcBuf.baseAddress!, count: n)
            }
        }
        var imagIn = [Float](repeating: 0, count: fftN)

        // 3. FFT
        let log2n = vDSP_Length(Int(log2(Double(fftN))))
        guard let setup = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            return [Float](repeating: 0, count: bandCount)
        }
        var realOut = [Float](repeating: 0, count: fftN / 2)
        var imagOut = [Float](repeating: 0, count: fftN / 2)
        var input = DSPSplitComplex(realp: &realIn, imagp: &imagIn)
        var output = DSPSplitComplex(realp: &realOut, imagp: &imagOut)
        setup.forward(input: input, output: &output)

        // 4. 幅度谱
        var magnitudes = [Float](repeating: 0, count: fftN / 2)
        vDSP_zvabs(&output, 1, &magnitudes, 1, vDSP_Length(fftN / 2))

        // 5. 对数频段聚合 20Hz..20kHz, 64 段
        var bands = [Float](repeating: 0, count: bandCount)
        let nyquist = sampleRate / 2
        let maxFreq: Float = min(20000, nyquist)
        let minFreq: Float = 20
        let ratio = maxFreq / minFreq
        for b in 0..<bandCount {
            let lo = minFreq * pow(ratio, Float(b) / Float(bandCount))
            let hi = minFreq * pow(ratio, Float(b + 1) / Float(bandCount))
            let loBin = max(1, Int(lo * Float(fftN) / sampleRate))
            let hiBin = max(loBin + 1, Int(hi * Float(fftN) / sampleRate))
            var sum: Float = 0
            var cnt = 0
            for i in loBin..<min(hiBin, fftN / 2) {
                sum += magnitudes[i]
                cnt += 1
            }
            bands[b] = cnt > 0 ? sum / Float(cnt) : 0
        }

        // 6. 归一化到 0...1(按帧最大值,避免不同音量下频谱条过满或太空)
        if let maxBand = bands.max(), maxBand > 0 {
            let scale = 1.0 / maxBand
            vDSP_vsmul(bands, 1, [scale], &bands, 1, vDSP_Length(bandCount))
        }
        return bands
    }

    /// 测试入口:直接喂样本计算频段,跳过 AVAudioTap。
    func computeBandsForTest(samples: [Float], sampleRate: Double, count: Int) -> [Float] {
        computeBands(samples: samples, sampleRate: Float(sampleRate), count: count)
    }
}