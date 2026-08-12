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