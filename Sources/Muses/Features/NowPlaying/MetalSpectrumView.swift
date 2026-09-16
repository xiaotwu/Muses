import SwiftUI
import Metal
import MetalKit
import AppKit

/// Metal hardware-accelerated spectrum visualization (an NSViewRepresentable
/// wrapping MTKView).
///
/// The Metal shader is compiled at launch (vertices are generated procedurally:
/// 64 bars x 2 quads = 768 vertices) and renders at 30 FPS the upper gradient
/// bars plus a 30%-opacity mirrored lower half. Spectrum data is written from
/// the audio thread through a thread-safe buffer; the MTKView delegate thread
/// reads it, applies peak decay, and renders.
struct MetalSpectrumView: NSViewRepresentable {
    var onUnavailable: () -> Void = {}
    @Environment(PlaybackService.self) private var playback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> MTKView {
        let renderer = SpectrumRenderer()
        let mtkView = MTKView(frame: .zero, device: renderer.device)
        mtkView.device = renderer.device
        mtkView.delegate = renderer
        mtkView.preferredFramesPerSecond = 30
        mtkView.framebufferOnly = true
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = reduceMotion || !playback.transportState.isPlaying || playback.transportState.audioProcessing != .available
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.wantsLayer = true
        mtkView.layer?.isOpaque = false

        context.coordinator.renderer = renderer
        if !renderer.isAvailable {
            let coordinator = context.coordinator
            DispatchQueue.main.async { if coordinator.isActive { onUnavailable() } }
        }
        context.coordinator.setSampling(!mtkView.isPaused && renderer.isAvailable)
        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        let shouldPause = reduceMotion || !playback.transportState.isPlaying || playback.transportState.audioProcessing != .available
        context.coordinator.setSampling(!shouldPause && context.coordinator.renderer?.isAvailable == true)
        guard nsView.isPaused != shouldPause else { return }
        nsView.isPaused = shouldPause
        AppLog.for("Spectrum").notice("metal paused=\(shouldPause, privacy: .public) frames=\(context.coordinator.renderer?.renderedFrames ?? 0, privacy: .public)")
        if shouldPause { nsView.setNeedsDisplay(nsView.bounds) }
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        coordinator.isActive = false
        coordinator.setSampling(false)
        nsView.isPaused = true
        nsView.delegate = nil
        coordinator.renderer?.cleanup()
        coordinator.renderer = nil
        if let owner = coordinator.owner { coordinator.playback?.removeSpectrumHandler(owner: owner) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(playback: playback) }

    @MainActor final class Coordinator {
        weak var playback: PlaybackService?
        var owner: UUID?
        var renderer: SpectrumRenderer?
        var isActive = true
        func setSampling(_ enabled: Bool) {
            if enabled, isActive, owner == nil, let renderer, renderer.isAvailable {
                owner = playback?.installSpectrumHandler { renderer.updateBands($0.bands) }
            } else if !enabled, let owner {
                playback?.removeSpectrumHandler(owner: owner)
                self.owner = nil
            }
        }
        init(playback: PlaybackService) { self.playback = playback }
    }
}

/// MTKView delegate: manages the Metal device, pipeline, command-owned uniforms, and
/// per-frame rendering.
final class SpectrumRenderer: NSObject, MTKViewDelegate {
    var isAvailable: Bool { !cleanedUp && device != nil && commandQueue != nil && pipelineState != nil }
    let device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var cleanedUp = false
    private(set) var renderedFrames = 0
    private var lastDrawableSize = CGSize.zero

    /// Thread-safe spectrum data buffer (64 bands, 0...1).
    private let bufferLock = NSLock()
    private var receivedSamples = 0
    private var maximumSample: Float = 0
    private var rawBands: [Float] = Array(repeating: 0, count: 64)
    private var peaks: [Float] = Array(repeating: 0, count: 64)
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private let peakDecayPerSecond: Float = 1.0 / 0.2
    private let bandCount = 64

    /// Uniform struct layout (mirrors Uniforms in the Metal shader):
    /// 64 Float bands + 7 Float (width, height, barWidth, gap, midY, pad)

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), shaderSource: String? = nil) {
        self.device = device
        commandQueue = device?.makeCommandQueue()
        pipelineState = Self.makePipelineState(device: device, sourceOverride: shaderSource)
        super.init()
        AppLog.for("Spectrum").notice("metal created available=\(self.isAvailable, privacy: .public)")
    }

    /// Compiles the Metal shader at runtime and creates the pipeline state.
    private static func makePipelineState(device: MTLDevice?, sourceOverride: String?) -> MTLRenderPipelineState? {
        guard let device else { return nil }
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct Uniforms {
            float bands[64];
            float width;
            float height;
            float barWidth;
            float gap;
            float midY;
            float pad1;
            float pad2;
        };

        struct VSOut {
            float4 position [[position]];
            float4 color;
        };

        // Procedural vertices: 768 = 64 bars x 2 quads (upper + lower) x 6
        // vertices (2 triangles).
        vertex VSOut spectrum_vertex(uint vid [[vertex_id]], constant Uniforms& u [[buffer(0)]]) {
            uint quadIdx = vid / 6u;       // 0..127
            uint corner  = vid % 6u;       // 0..5
            bool isLower = quadIdx >= 64u;
            uint bar = quadIdx % 64u;

            float v = u.bands[bar];
            float barH = v * u.midY;

            // Bar x position: 64 bars + 1 gap width.
            float unit = u.width / 65.0;
            float barWidth = unit * 0.8;
            float gap = unit * 0.2;
            float x0 = unit + float(bar) * (barWidth + gap);

            // Quad's 6 vertices (two triangles).
            // Local coordinates: origin at the bar's bottom inner corner;
            // (0,0) = bottom-left, (barWidth, barH) = top-right.
            float2 corners[6];
            corners[0] = float2(0.0, 0.0);
            corners[1] = float2(barWidth, 0.0);
            corners[2] = float2(0.0, barH);
            corners[3] = float2(barWidth, 0.0);
            corners[4] = float2(barWidth, barH);
            corners[5] = float2(0.0, barH);
            float2 c = corners[corner];

            float px = x0 + c.x;
            float py = isLower ? (u.midY + c.y) : (u.midY - c.y);

            // Convert to clip space (Metal's y points down).
            float ndcX = (px / u.width) * 2.0 - 1.0;
            float ndcY = -((py / u.height) * 2.0 - 1.0);

            VSOut out;
            out.position = float4(ndcX, ndcY, 0.0, 1.0);

            if (isLower) {
                // Mirror: accent at 30% opacity.
                out.color = float4(0.98, 0.98, 0.99, 0.3);
            } else {
                // Upper half: accent gradient (100% at the bottom -> 70% at the
                // top, keeping a slight sense of depth).
                float t = barH > 0.001 ? (c.y / barH) : 0.0;
                float v = 1.0 - t * 0.3;
                out.color = float4(0.98, 0.98, 0.99, v);
            }
            return out;
        }

        fragment float4 spectrum_fragment(VSOut in [[stage_in]]) {
            return in.color;
        }
        """
        guard let library = try? device.makeLibrary(source: sourceOverride ?? source, options: nil) else { return nil }
        let vertexFn = library.makeFunction(name: "spectrum_vertex")
        let fragmentFn = library.makeFunction(name: "spectrum_fragment")

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        // Enable blending (needed for the translucent mirror).
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        return try? device.makeRenderPipelineState(descriptor: desc)
    }

    /// Called on the audio thread: thread-safe write of the raw band data.
    func updateBands(_ bands: [Float]) {
        guard bands.count == bandCount else { return }
        guard bufferLock.try() else { return }
        rawBands = bands
        receivedSamples += 1
        maximumSample = max(maximumSample, bands.max() ?? 0)
        bufferLock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard !cleanedUp, !view.isPaused, view.drawableSize.width > 0, view.drawableSize.height > 0,
              let drawable = view.currentDrawable,
              let desc = view.currentRenderPassDescriptor,
              let cmd = commandQueue?.makeCommandBuffer(),
              let encoder = cmd.makeRenderCommandEncoder(descriptor: desc),
              let pipeline = pipelineState
        else { return }

        // Read the latest bands and apply peak decay (runs on the Metal thread).
        let now = CACurrentMediaTime()
        let dt = Float(max(0, min(1.0 / 10.0, now - lastFrameTime)))
        let decay = peakDecayPerSecond * dt

        bufferLock.lock()
        let bands = rawBands
        bufferLock.unlock()

        for i in 0..<bandCount {
            peaks[i] = max(bands[i], peaks[i] - decay)
        }
        lastFrameTime = now

        lastDrawableSize = view.drawableSize
        encode(encoder: encoder, pipeline: pipeline, size: view.drawableSize, bands: peaks)
        encoder.endEncoding()
        cmd.present(drawable)
        cmd.commit()
        renderedFrames += 1
    }

    private func encode(encoder: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState,
                        size: CGSize, bands: [Float]) {
        let unit = Float(size.width) / 65.0
        var uniforms = [Float](repeating: 0, count: 64 + 8)
        for i in 0..<bandCount { uniforms[i] = bands[i] }
        uniforms[64] = Float(size.width)
        uniforms[65] = Float(size.height)
        uniforms[66] = unit * 0.8
        uniforms[67] = unit * 0.2
        uniforms[68] = Float(size.height) / 2.0
        encoder.setRenderPipelineState(pipeline)
        uniforms.withUnsafeBytes { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 768)
    }

    #if DEBUG
    /// Offscreen GPU readback verifies the real shader, independent of window compositing.
    func renderPixelsForTest() -> [UInt8]? {
        guard let device, let pipelineState, let commandQueue else { return nil }
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 260, height: 100, mipmapped: false)
        textureDescriptor.usage = [.renderTarget]
        textureDescriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: textureDescriptor),
              let command = commandQueue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encode(encoder: encoder, pipeline: pipelineState, size: CGSize(width: 260, height: 100),
               bands: Array(repeating: 0.75, count: 64))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        var pixels = [UInt8](repeating: 0, count: 260 * 100 * 4)
        pixels.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: 260 * 4,
                from: MTLRegionMake2D(0, 0, 260, 100), mipmapLevel: 0)
        }
        return pixels
    }
    #endif

    func cleanup() {
        guard !cleanedUp else { return }
        bufferLock.lock()
        let sampleCount = receivedSamples
        let maximum = maximumSample
        bufferLock.unlock()
        AppLog.for("Spectrum").notice("metal stopped frames=\(self.renderedFrames, privacy: .public) samples=\(sampleCount, privacy: .public) max=\(maximum, privacy: .public) width=\(self.lastDrawableSize.width, privacy: .public) height=\(self.lastDrawableSize.height, privacy: .public)")
        cleanedUp = true
        commandQueue = nil
        pipelineState = nil
    }
}
