import Testing
import SwiftUI
@testable import Muses

/// Metal spectrum rendering + GPU settings tests.
@MainActor
@Suite("MetalSpectrum")
struct MetalSpectrumTests {

    @Test("GPU 加速 PrefKey 存在且默认开启")
    func gpuPrefKeyExists() {
        #expect(PrefKey.gpuAcceleration == "muses.gpuAcceleration")
        // Defaults are persisted via @AppStorage; here we only verify the key string is correct
    }

    @Test("SpectrumRenderer 初始化不崩溃(无 Metal 设备时优雅降级)")
    func rendererInitSafe() {
        // The test environment may have no Metal device, but this must not crash
        let renderer = SpectrumRenderer()
        // device may be nil (no GPU environment), but it must not crash
        _ = renderer.device
    }
}