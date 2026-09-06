import Testing
import Foundation
import AVFoundation
@testable import Muses

@MainActor
@Suite("SpectrumTap FFT")
struct SpectrumTapFFTTests {
    @Test("Sine wave peak falls within expected frequency band")
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
        // 1kHz lands roughly mid-band under the log mapping 20Hz..20kHz (around bins 30-45)
        let maxVal = bands.max() ?? 0
        let peakIdx = bands.firstIndex(of: maxVal) ?? -1
        #expect(peakIdx > 20 && peakIdx < 55)
        #expect(maxVal > 0.1)   // a sine wave should show clear energy
    }

    @Test("Silent input produces near-zero bands")
    func silenceIsNearZero() {
        let samples = [Float](repeating: 0, count: 1024)
        let tap = SpectrumTap()
        let bands = tap.computeBandsForTest(samples: samples, sampleRate: 44100, count: 64)
        #expect(bands.allSatisfy { $0 < 0.01 })
    }

    @Test("Low frequency sine peak falls in lower band")
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
        // 80Hz should land in the first few bins (low frequency)
        #expect(peakIdx < 15)
    }
}