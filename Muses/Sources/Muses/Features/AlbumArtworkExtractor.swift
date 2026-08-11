import AppKit
import CoreImage

enum AlbumArtworkExtractor {
    static func dominantColors(_ image: NSImage, count: Int = 3) -> [NSColor] {
        guard count > 0 else { return [] }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let ci = CIImage(cgImage: cg)
        let originalExtent = ci.extent
        guard originalExtent.width > 0, originalExtent.height > 0 else { return [] }

        // 缩放到 64x64 以内, 加速 CIAreaAverage
        let scale = min(64.0 / originalExtent.width, 64.0 / originalExtent.height, 1.0)
        let scaled = scale < 1.0 ? ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : ci
        let extent = scaled.extent
        guard extent.width > 0, extent.height > 0 else { return [] }

        guard let filter = CIFilter(name: "CIAreaAverage") else { return [] }
        filter.setValue(scaled, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return [] }

        // 渲染到 1x1 RGBA 位图取平均色
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        var bytes = [UInt8](repeating: 0, count: 4)
        let ciContext = CIContext(options: nil)
        let outExtent = output.extent
        guard outExtent.width > 0, outExtent.height > 0 else { return [] }
        ciContext.render(output,
                         toBitmap: &bytes,
                         rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8,
                         colorSpace: colorSpace)
        let avg = NSColor(srgbRed: CGFloat(bytes[0]) / 255.0,
                          green: CGFloat(bytes[1]) / 255.0,
                          blue: CGFloat(bytes[2]) / 255.0,
                          alpha: 1)
        var colors: [NSColor] = [avg]
        if colors.count < count {
            colors.append(avg.shadow(withLevel: 0.4) ?? avg)
        }
        if colors.count < count {
            colors.append(avg.highlight(withLevel: 0.3) ?? avg)
        }
        return Array(colors.prefix(count))
    }
}
