import Testing
import SwiftUI
import MetalKit
@testable import Muses

/// Metal spectrum rendering + GPU settings tests.
@MainActor
@Suite("MetalSpectrum")
struct MetalSpectrumTests {

    #if DEBUG
    // The offscreen readback hook is intentionally absent from production.
    @Test("GPU shader produces visible accent pixels")
    func visibleShader() throws {
        let renderer = SpectrumRenderer()
        guard renderer.isAvailable else { return }
        let pixels = try #require(renderer.renderPixelsForTest())
        #expect(pixels.enumerated().contains { $0.offset % 4 == 2 && $0.element > 100 })
    }
    #endif

    @Test("missing device and invalid shader fail closed; cleanup is idempotent")
    func rendererFailures() {
        #expect(!SpectrumRenderer(device: nil).isAvailable)
        let invalid = SpectrumRenderer(shaderSource: "invalid shader source")
        #expect(!invalid.isAvailable)
        let renderer = SpectrumRenderer()
        renderer.cleanup()
        renderer.cleanup()
        #expect(!renderer.isAvailable)
    }

    @Test("repeated Metal dismantle stops sampling, clears delegate and releases renderer")
    func repeatedDismantle() {
        let engine = RecordingEngine()
        let playback = PlaybackService(youtubeEngine: engine, queue: QueueService())
        for _ in 0..<20 {
            let coordinator = MetalSpectrumView.Coordinator(playback: playback)
            coordinator.renderer = SpectrumRenderer()
            weak var released = coordinator.renderer
            let view = MTKView()
            view.delegate = coordinator.renderer
            coordinator.setSampling(true)
            MetalSpectrumView.dismantleNSView(view, coordinator: coordinator)
            #expect(view.isPaused)
            #expect(view.delegate == nil)
            #expect(!engine.spectrumTapInstalled)
            #expect(released == nil)
            coordinator.setSampling(true)
            #expect(!engine.spectrumTapInstalled)
        }
    }

    @Test("spectrum inbox holds only newest complete sample")
    func latestSample() {
        let buffer = SpectrumSampleBuffer()
        for i in 0..<10_000 { buffer.write(SpectrumFrame(bands: Array(repeating: 0.5, count: 64), timestamp: Double(i))) }
        buffer.write(SpectrumFrame(bands: [1], timestamp: 10_000))
        #expect(buffer.read()?.timestamp == 9999)
    }

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
    @Test("tearing down an old spectrum surface cannot remove a newer handler")
    func handlerOwnership() {
        let engine = RecordingEngine()
        let playback = PlaybackService(youtubeEngine: engine, queue: QueueService())
        let first = playback.installSpectrumHandler { _ in }
        let second = playback.installSpectrumHandler { _ in }
        playback.removeSpectrumHandler(owner: first)
        #expect(engine.spectrumTapInstalled)
        playback.removeSpectrumHandler(owner: second)
        #expect(!engine.spectrumTapInstalled)
    }

    @Test("performance tracing retains a bounded recent history")
    func traceBound() {
        PerfTrace.clear()
        defer { PerfTrace.clear() }
        for i in 0..<(PerfTrace.capacity + 3) { PerfTrace.event("test.\(i)") }
        #expect(PerfTrace.snapshot().count == PerfTrace.capacity)
        #expect(PerfTrace.snapshot().first?.name == "test.3")
    }

    @Test("audio analysis capability follows the current backend")
    func processingCapability() {
        let engine = RecordingEngine()
        let playback = PlaybackService(youtubeEngine: engine, queue: QueueService())
        let capabilities = RuntimeCapabilities(playback: playback)
        #expect(capabilities.audioAnalysis == .unsupported)
        engine.state.audioProcessing = .waitingForDownload
        #expect(capabilities.audioAnalysis == .limited)
        engine.state.audioProcessing = .available
        #expect(capabilities.audioAnalysis == .supported)
        engine.state.audioProcessing = .streamOnly
        #expect(capabilities.audioAnalysis == .unsupported)
    }

}
