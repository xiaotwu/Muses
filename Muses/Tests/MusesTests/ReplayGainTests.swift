import Testing
import Foundation
@testable import Muses

@Suite("ReplayGain")
struct ReplayGainTests {

    // MARK: - parseReplayGain 字符串解析

    @Test("parseReplayGain 解析 '-6.43 dB' → -6.43")
    func parseReplayGainWithDB() {
        #expect(MetadataService.parseReplayGain("-6.43 dB") == -6.43)
    }

    @Test("parseReplayGain 解析无 dB 后缀")
    func parseReplayGainWithoutDB() {
        #expect(MetadataService.parseReplayGain("-3.5") == -3.5)
        #expect(MetadataService.parseReplayGain("2.0") == 2.0)
    }

    @Test("parseReplayGain 正增益")
    func parseReplayGainPositive() {
        #expect(MetadataService.parseReplayGain("+4.2 dB") == 4.2)
    }

    @Test("parseReplayGain 无效字符串返回 nil")
    func parseReplayGainInvalid() {
        #expect(MetadataService.parseReplayGain("N/A") == nil)
        #expect(MetadataService.parseReplayGain("") == nil)
    }

    // MARK: - replayGainScale 增益因子计算

    @Test("replayGainScale: -6 dB ≈ 0.501")
    func scaleNegative6dB() {
        let scale = MetadataService.replayGainScale(-6.0)
        #expect(abs(scale - 0.501) < 0.01)
    }

    @Test("replayGainScale: 0 dB = 1.0")
    func scaleZero() {
        #expect(MetadataService.replayGainScale(0.0) == 1.0)
    }

    @Test("replayGainScale: +6 dB ≈ 1.995")
    func scalePositive6dB() {
        let scale = MetadataService.replayGainScale(6.0)
        #expect(abs(scale - 1.995) < 0.01)
    }

    @Test("replayGainScale: nil → 1.0(无标签不影响音量)")
    func scaleNil() {
        #expect(MetadataService.replayGainScale(nil) == 1.0)
    }
}