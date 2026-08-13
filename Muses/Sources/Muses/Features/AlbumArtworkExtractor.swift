import AppKit
import CoreImage

/// 专辑封面颜色提取器:使用 k-means 聚类提取多个主色调。
enum AlbumArtworkExtractor {
    /// 从图片提取 `count` 个主色调(按饱和度排序,最鲜艳的在前)。
    ///
    /// 使用 k-means 聚类(Lloyd's algorithm)对缩小后的像素进行分组,
    /// 返回各簇中心色,比单像素 CIAreaAverage + shadow/highlight 更能代表真实多色调色板。
    static func dominantColors(_ image: NSImage, count: Int = 3) -> [NSColor] {
        guard count > 0 else { return [] }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }

        // 缩小到 32x32 提取像素(1024 像素,k-means <1ms)
        let targetSize = 32
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetSize,
            pixelsHigh: targetSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: targetSize * 4,
            bitsPerPixel: 32
        ) else { return [] }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: targetSize, height: targetSize))
        NSGraphicsContext.restoreGraphicsState()

        // 收集所有像素的 RGB
        var pixels: [(r: Double, g: Double, b: Double)] = []
        pixels.reserveCapacity(targetSize * targetSize)
        for y in 0..<targetSize {
            for x in 0..<targetSize {
                if let nsColor = bitmap.colorAt(x: x, y: y) {
                    let r = nsColor.redComponent
                    let g = nsColor.greenComponent
                    let b = nsColor.blueComponent
                    // 跳过近透明像素
                    if nsColor.alphaComponent > 0.5 {
                        pixels.append((Double(r), Double(g), Double(b)))
                    }
                }
            }
        }
        guard !pixels.isEmpty else { return [] }

        // k-means 聚类
        let k = min(count, pixels.count)
        let centers = kmeans(pixels: pixels, k: k, iterations: 10)

        // 转换为 NSColor,按饱和度排序(最鲜艳在前)
        let colors = centers.map { c in
            NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1)
        }.sorted { a, b in
            saturation(a) > saturation(b)
        }

        return Array(colors.prefix(count))
    }

    /// 简单 k-means(Lloyd's algorithm)。
    private static func kmeans(pixels: [(r: Double, g: Double, b: Double)],
                               k: Int, iterations: Int) -> [(r: Double, g: Double, b: Double)] {
        // 初始化:均匀采样 k 个像素作为初始中心
        var centers: [(r: Double, g: Double, b: Double)] = []
        let step = max(1, pixels.count / k)
        for i in 0..<k {
            centers.append(pixels[i * step % pixels.count])
        }

        for _ in 0..<iterations {
            // 分配:每个像素到最近的中心
            var clusters: [[Int]] = Array(repeating: [], count: k)
            for (idx, px) in pixels.enumerated() {
                var bestCluster = 0
                var bestDist = Double.infinity
                for (ci, c) in centers.enumerated() {
                    let d = (px.r - c.r) * (px.r - c.r)
                            + (px.g - c.g) * (px.g - c.g)
                            + (px.b - c.b) * (px.b - c.b)
                    if d < bestDist {
                        bestDist = d
                        bestCluster = ci
                    }
                }
                clusters[bestCluster].append(idx)
            }

            // 更新:重新计算中心
            for (ci, cluster) in clusters.enumerated() {
                guard !cluster.isEmpty else { continue }
                var sumR: Double = 0, sumG: Double = 0, sumB: Double = 0
                for idx in cluster {
                    sumR += pixels[idx].r
                    sumG += pixels[idx].g
                    sumB += pixels[idx].b
                }
                let n = Double(cluster.count)
                centers[ci] = (sumR / n, sumG / n, sumB / n)
            }
        }

        return centers
    }

    /// 计算 NSColor 的饱和度(HSB)。
    private static func saturation(_ color: NSColor) -> CGFloat {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return s
    }
}