import SwiftUI
import Metal
import MetalKit
import AppKit

/// Metal 硬件加速频谱可视化(NSViewRepresentable 包装 MTKView)。
///
/// 在启动时编译 Metal shader(顶点过程式生成 64 柱 × 2 四边形 = 768 顶点),
/// 60 FPS 渲染上半部分 Magenta→Cyan 渐变柱与下半部分 30% 透明镜像。
/// 频谱数据通过线程安全缓冲区从音频线程写入,MTKView 委托线程读取并做峰值衰减后渲染。
struct MetalSpectrumView: NSViewRepresentable {
    @Environment(PlaybackService.self) private var playback

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        let renderer = SpectrumRenderer()
        mtkView.device = renderer.device
        mtkView.delegate = renderer
        mtkView.preferredFramesPerSecond = 60
        mtkView.framebufferOnly = true
        mtkView.isPaused = false
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtkView.colorPixelFormat = .bgra8Unorm

        // 频谱 handler:音频渲染线程调用 → 线程安全写入缓冲区
        playback.installSpectrumHandler { frame in
            renderer.updateBands(frame.bands)
        }

        context.coordinator.renderer = renderer
        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        coordinator.renderer?.cleanup()
        playback.removeSpectrumHandler()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: SpectrumRenderer?
    }
}

/// MTKView 委托:管理 Metal 设备、管线、uniform 缓冲区与每帧渲染。
final class SpectrumRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let pipelineState: MTLRenderPipelineState?
    private var uniformBuffer: MTLBuffer?

    /// 线程安全的频谱数据缓冲(64 段,0...1)
    private let bufferLock = NSLock()
    private var rawBands: [Float] = Array(repeating: 0, count: 64)
    private var peaks: [Float] = Array(repeating: 0, count: 64)
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private let peakDecayPerSecond: Float = 1.0 / 0.2
    private let bandCount = 64

    /// uniform 结构体布局(与 Metal shader 中 Uniforms 对齐):
    /// 64 Float bands + 6 Float (width, height, barWidth, gap, midY, pad)
    private let uniformSize = (64 + 8) * MemoryLayout<Float>.size

    override init() {
        device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        pipelineState = Self.makePipelineState(device: device)
        uniformBuffer = device?.makeBuffer(length: uniformSize, options: [])
        super.init()
    }

    /// 运行时编译 Metal shader 并创建管线状态。
    private static func makePipelineState(device: MTLDevice?) -> MTLRenderPipelineState? {
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

        // 过程式顶点:768 顶点 = 64 柱 × 2 四边形(上+下) × 6 顶点(2 三角形)
        vertex VSOut spectrum_vertex(uint vid [[vertex_id]], constant Uniforms& u [[buffer(0)]]) {
            uint quadIdx = vid / 6u;       // 0..127
            uint corner  = vid % 6u;       // 0..5
            bool isLower = quadIdx >= 64u;
            uint bar = quadIdx % 64u;

            float v = u.bands[bar];
            float barH = v * u.midY;

            // 柱 x 位置:64+1 间隙
            float unit = u.width / 65.0;
            float barWidth = unit * 0.8;
            float gap = unit * 0.2;
            float x0 = unit + float(bar) * (barWidth + gap);

            // 四边形 6 顶点(两个三角形)
            // 本地坐标:原点在柱底部内侧角,(0,0)=左下, (barWidth, barH)=右上
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

            // 转换到裁剪空间(Metal y 向下)
            float ndcX = (px / u.width) * 2.0 - 1.0;
            float ndcY = -((py / u.height) * 2.0 - 1.0);

            VSOut out;
            out.position = float4(ndcX, ndcY, 0.0, 1.0);

            if (isLower) {
                // 镜像:30% 透明 magenta
                out.color = float4(0.94, 0.56, 0.94, 0.3);
            } else {
                // 上半:magenta(底)→ cyan(顶)渐变
                float t = barH > 0.001 ? (c.y / barH) : 0.0;
                // magenta=(0.94,0.56,0.94) cyan=(0.09,0.66,0.94)
                out.color = float4(0.94 - t * 0.85, 0.56 + t * 0.10, 0.94, 1.0);
            }
            return out;
        }

        fragment float4 spectrum_fragment(VSOut in [[stage_in]]) {
            return in.color;
        }
        """
        guard let library = try? device.makeLibrary(source: source, options: nil) else { return nil }
        let vertexFn = library.makeFunction(name: "spectrum_vertex")
        let fragmentFn = library.makeFunction(name: "spectrum_fragment")

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        // 启用混合(镜像半透明需要)
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        return try? device.makeRenderPipelineState(descriptor: desc)
    }

    /// 音频线程调用:线程安全写入原始频段数据。
    func updateBands(_ bands: [Float]) {
        guard bands.count == bandCount else { return }
        bufferLock.lock()
        rawBands = bands
        bufferLock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let desc = view.currentRenderPassDescriptor,
              let buffer = uniformBuffer,
              let cmd = commandQueue?.makeCommandBuffer(),
              let encoder = cmd.makeRenderCommandEncoder(descriptor: desc),
              let pipeline = pipelineState
        else { return }

        // 读取最新频段 + 峰值衰减(在 Metal 线程执行)
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

        // 填充 uniform 缓冲区
        let size = view.drawableSize
        let unit = Float(size.width) / 65.0
        var uniforms = [Float](repeating: 0, count: 64 + 8)
        for i in 0..<bandCount { uniforms[i] = peaks[i] }
        uniforms[64] = Float(size.width)
        uniforms[65] = Float(size.height)
        uniforms[66] = unit * 0.8
        uniforms[67] = unit * 0.2
        uniforms[68] = Float(size.height) / 2.0
        memcpy(buffer.contents(), uniforms, uniformSize)

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 768)
        encoder.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    func cleanup() {
        uniformBuffer = nil
    }
}