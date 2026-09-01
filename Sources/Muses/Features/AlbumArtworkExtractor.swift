import AppKit
import CoreImage

/// Album artwork color extractor: uses k-means clustering to pull multiple dominant colors.
enum AlbumArtworkExtractor {
    /// Extracts `count` dominant colors from an image (sorted by saturation, most vivid first).
    ///
    /// Uses k-means clustering (Lloyd's algorithm) over downscaled pixels and returns each
    /// cluster's center color — a better representation of a real multi-hue palette than a
    /// single-pixel CIAreaAverage plus shadow/highlight.
    static func dominantColors(_ image: NSImage, count: Int = 3) -> [NSColor] {
        guard count > 0 else { return [] }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }

        // Downscale to 32x32 for pixel extraction (1024 pixels; k-means < 1ms)
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

        // Collect the RGB of every pixel
        var pixels: [(r: Double, g: Double, b: Double)] = []
        pixels.reserveCapacity(targetSize * targetSize)
        for y in 0..<targetSize {
            for x in 0..<targetSize {
                if let nsColor = bitmap.colorAt(x: x, y: y) {
                    let r = nsColor.redComponent
                    let g = nsColor.greenComponent
                    let b = nsColor.blueComponent
                    // Skip nearly transparent pixels
                    if nsColor.alphaComponent > 0.5 {
                        pixels.append((Double(r), Double(g), Double(b)))
                    }
                }
            }
        }
        guard !pixels.isEmpty else { return [] }

        // k-means clustering
        let k = min(count, pixels.count)
        let centers = kmeans(pixels: pixels, k: k, iterations: 10)

        // Convert to NSColor and sort by saturation (most vivid first)
        let colors = centers.map { c in
            NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1)
        }.sorted { a, b in
            saturation(a) > saturation(b)
        }

        return Array(colors.prefix(count))
    }

    /// Simple k-means (Lloyd's algorithm).
    private static func kmeans(pixels: [(r: Double, g: Double, b: Double)],
                               k: Int, iterations: Int) -> [(r: Double, g: Double, b: Double)] {
        // Initialize: evenly sample k pixels as the initial centers
        var centers: [(r: Double, g: Double, b: Double)] = []
        let step = max(1, pixels.count / k)
        for i in 0..<k {
            centers.append(pixels[i * step % pixels.count])
        }

        for _ in 0..<iterations {
            // Assignment: each pixel to its nearest center
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

            // Update: recompute the centers
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

    /// Computes an NSColor's saturation (HSB).
    private static func saturation(_ color: NSColor) -> CGFloat {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return s
    }
}