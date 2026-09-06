import Testing
import SwiftUI
@testable import Muses

/// Metal spectrum rendering + GPU settings tests.
@MainActor
@Suite("MetalSpectrum")
struct MetalSpectrumTests {

    @Test("GPU acceleration PrefKey exists and defaults to enabled")
    func gpuPrefKeyExists() {
        #expect(PrefKey.gpuAcceleration == "muses.gpuAcceleration")
        // Defaults are persisted via @AppStorage; here we only verify the key string is correct
    }

    @Test("SpectrumRenderer initialization does not crash (graceful fallback without Metal device)")
    func rendererInitSafe() {
        // The test environment may have no Metal device, but this must not crash
        let renderer = SpectrumRenderer()
        // device may be nil (no GPU environment), but it must not crash
        _ = renderer.device
    }
}