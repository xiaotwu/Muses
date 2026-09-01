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
    // Reused on the render thread — do not allocate in `process`.
    private var mixBuffer: [Float] = []
    private var window: [Float] = []
    private var windowed: [Float] = []
    private var fftN = 0
    private var fftSetup: vDSP.FFT<DSPSplitComplex>?
    private var realIn: [Float] = []
    private var imagIn: [Float] = []
    private var realOut: [Float] = []
    private var imagOut: [Float] = []
    private var magnitudes: [Float] = []
    private var bandScratch: [Float] = []

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
        if mixBuffer.count != frameCount {
            mixBuffer = [Float](repeating: 0, count: frameCount)
        }
        let channels = Int(buffer.format.channelCount)
        let inv = channels > 0 ? 1 / Float(channels) : 1
        for i in 0..<frameCount {
            var s: Float = 0
            for c in 0..<channels { s += ch[c][i] }
            mixBuffer[i] = s * inv
        }

        let bands = computeBands(samples: mixBuffer, sampleRate: Float(buffer.format.sampleRate), count: bandCount)
        handler(SpectrumFrame(bands: bands, timestamp: now))
    }

    // MARK: - FFT

    /// 对数频段映射的 vDSP FFT 频谱计算。
    /// - Parameters:
    ///   - samples: 单声道样本(已 mono mix)。
    ///   - sampleRate: 采样率(Hz)。
    ///   - count: 输出频段数(内部固定为 bandCount=64,参数保留以兼容旧调用)。
    /// - Returns: 归一化到 0...1 的频段数组,长度为 bandCount。
    private func ensureFFTCapacity(sampleCount n: Int) {
        let nextN = 1 << (Int.bitWidth - n.leadingZeroBitCount)
        if nextN != fftN {
            fftN = nextN
            let log2n = vDSP_Length(Int(log2(Double(max(fftN, 2)))))
            fftSetup = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)
            realIn = [Float](repeating: 0, count: fftN)
            imagIn = [Float](repeating: 0, count: fftN)
            realOut = [Float](repeating: 0, count: fftN / 2)
            imagOut = [Float](repeating: 0, count: fftN / 2)
            magnitudes = [Float](repeating: 0, count: fftN / 2)
        }
        if window.count != n {
            window = [Float](repeating: 0, count: n)
            vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
            windowed = [Float](repeating: 0, count: n)
        }
        if bandScratch.count != bandCount {
            bandScratch = [Float](repeating: 0, count: bandCount)
        }
    }

    private func computeBands(samples: [Float], sampleRate: Float, count: Int) -> [Float] {
        let n = samples.count
        guard n > 1 else { return [Float](repeating: 0, count: bandCount) }
        ensureFFTCapacity(sampleCount: n)
        guard let setup = fftSetup, fftN > 1 else {
            return [Float](repeating: 0, count: bandCount)
        }

        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))
        for i in 0..<fftN { realIn[i] = 0; imagIn[i] = 0 }
        realIn.withUnsafeMutableBufferPointer { dstBuf in
            windowed.withUnsafeBufferPointer { srcBuf in
                dstBuf.baseAddress!.update(from: srcBuf.baseAddress!, count: n)
            }
        }

        realIn.withUnsafeMutableBufferPointer { realInputBuffer in
            imagIn.withUnsafeMutableBufferPointer { imaginaryInputBuffer in
                realOut.withUnsafeMutableBufferPointer { realOutputBuffer in
                    imagOut.withUnsafeMutableBufferPointer { imaginaryOutputBuffer in
                        guard
                            let realInput = realInputBuffer.baseAddress,
                            let imaginaryInput = imaginaryInputBuffer.baseAddress,
                            let realOutput = realOutputBuffer.baseAddress,
                            let imaginaryOutput = imaginaryOutputBuffer.baseAddress
                        else { return }

                        let input = DSPSplitComplex(realp: realInput, imagp: imaginaryInput)
                        var output = DSPSplitComplex(realp: realOutput, imagp: imaginaryOutput)
                        setup.forward(input: input, output: &output)

                        magnitudes.withUnsafeMutableBufferPointer { magnitudeBuffer in
                            guard let magnitudeOutput = magnitudeBuffer.baseAddress else { return }
                            vDSP_zvabs(
                                &output,
                                1,
                                magnitudeOutput,
                                1,
                                vDSP_Length(fftN / 2)
                            )
                        }
                    }
                }
            }
        }

        let nyquist = sampleRate / 2
        let maxFreq: Float = min(20000, nyquist)
        let minFreq: Float = 20
        let ratio = maxFreq / minFreq
        for b in 0..<bandCount { bandScratch[b] = 0 }
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
            bandScratch[b] = cnt > 0 ? sum / Float(cnt) : 0
        }

        if let maxBand = bandScratch.max(), maxBand > 0 {
            let scale = 1.0 / maxBand
            vDSP_vsmul(bandScratch, 1, [scale], &bandScratch, 1, vDSP_Length(bandCount))
        }
        return bandScratch
    }

    /// 测试入口:直接喂样本计算频段,跳过 AVAudioTap。
    func computeBandsForTest(samples: [Float], sampleRate: Double, count: Int) -> [Float] {
        computeBands(samples: samples, sampleRate: Float(sampleRate), count: count)
    }
}
