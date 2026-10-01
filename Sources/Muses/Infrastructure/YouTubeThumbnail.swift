import AppKit
import Foundation

/// YouTube thumbnail URLs and letterbox stripping.
///
/// `hqdefault` / `sddefault` / `default` are 4:3 frames with 16:9 content and
/// 12.5% black bars top and bottom. Crop those bars at decode so square covers
/// and 16:9 wells never show the matte.
enum YouTubeThumbnail {
    /// Canonical stored URL (hqdefault). Display crops letterbox.
    static func urlString(videoId: String) -> String {
        "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg"
    }

    static func url(videoId: String) -> URL? {
        URL(string: urlString(videoId: videoId))
    }

    /// Upgrade display-only YouTube thumbnail requests; persisted artwork URLs stay stable.
    static func displayCandidates(for url: URL, pixelSize: CGFloat) -> [URL] {
        guard pixelSize > 480,
              ["i.ytimg.com", "img.youtube.com"].contains(url.host?.lowercased() ?? ""),
              url.pathComponents.count == 4,
              ["vi", "vi_webp"].contains(url.pathComponents[1]),
              ["default", "mqdefault", "hqdefault", "sddefault"].contains(url.deletingPathExtension().lastPathComponent)
        else { return [url] }
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        return [directory.appendingPathComponent("maxresdefault.\(ext)"),
                directory.appendingPathComponent("sddefault.\(ext)"), url]
            .reduce(into: [URL]()) { if !$0.contains($1) { $0.append($1) } }
    }

    static func isLetterboxed(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), host.contains("ytimg.com") else {
            return false
        }
        let path = url.path.lowercased()
        return path.contains("hqdefault")
            || path.contains("sddefault")
            || path.hasSuffix("/default.jpg")
            || path.hasSuffix("/default.webp")
    }

    /// Crop 4:3 YouTube letterbox (45/360 = 12.5% each edge). 16:9 images pass through.
    static func cropLetterboxIfNeeded(_ image: NSImage, url: URL? = nil) -> NSImage {
        if let url, !isLetterboxed(url) { return image }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        let width = CGFloat(cg.width)
        let height = CGFloat(cg.height)
        guard height > 0 else { return image }
        let aspect = width / height
        guard aspect >= 1.22 && aspect <= 1.48 else { return image }
        let bar = (height * 45.0 / 360.0).rounded(.down)
        let cropHeight = height - bar * 2
        guard bar > 0, cropHeight > 8 else { return image }
        let rect = CGRect(x: 0, y: bar, width: width, height: cropHeight)
        guard let cropped = cg.cropping(to: rect) else { return image }
        return NSImage(cgImage: cropped, size: NSSize(width: rect.width, height: rect.height))
    }
}
