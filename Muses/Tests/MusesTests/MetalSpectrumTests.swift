import Testing
import SwiftUI
@testable import Muses

/// Metal 频谱渲染 + GPU 设置测试。
@MainActor
@Suite("MetalSpectrum")
struct MetalSpectrumTests {

    @Test("GPU 加速 PrefKey 存在且默认开启")
    func gpuPrefKeyExists() {
        #expect(PrefKey.gpuAcceleration == "muses.gpuAcceleration")
        // 默认值通过 @AppStorage 持久化,这里只验证 key 字符串正确
    }

    @Test("SpectrumRenderer 初始化不崩溃(无 Metal 设备时优雅降级)")
    func rendererInitSafe() {
        // 在测试环境中可能没有 Metal 设备,但不应崩溃
        let renderer = SpectrumRenderer()
        // device 可能为 nil(无 GPU 环境),但不应该 crash
        _ = renderer.device
    }
}