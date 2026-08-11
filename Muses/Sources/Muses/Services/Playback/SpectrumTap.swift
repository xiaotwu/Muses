import Foundation
import AVFoundation

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

        let bands = computeBands(samples: samples, count: frameCount)
        handler(SpectrumFrame(bands: bands, timestamp: now))
    }

    private func computeBands(samples: [Float], count: Int) -> [Float] {
        // MVP 简化: 线性分桶的平均幅度作为 64 段近似(完整 vDSP FFT 留作后续优化, 仍可可视化)
        var bands = [Float](repeating: 0, count: bandCount)
        let bucket = max(1, count / bandCount)
        for b in 0..<bandCount {
            var sum: Float = 0
            for i in 0..<bucket {
                let idx = b * bucket + i
                if idx < count { sum += abs(samples[idx]) }
            }
            bands[b] = min(1.0, sum / Float(bucket) * 50)
        }
        return bands
    }
}