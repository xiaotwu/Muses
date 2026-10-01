import Foundation
import AppKit
import SwiftUI
import ImageIO

/// Shared URL requests and decoded-image cache. One consumer cancelling its
/// view task must not cancel a coalesced request needed by another surface.
/// A serial decoder keeps image decompression off the UI executor and bounds
/// concurrent decode memory. Cache cost reflects decoded pixels, not JPEG size.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private let session: URLSession
    private let memory: NSCache<NSString, NSImage> = .init()
    /// In-flight requests (URL -> Task), used for coalescing.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    init(session: URLSession = .shared) {
        self.session = session
        // ~50MB memory cap, enough for dozens of covers on Home.
        memory.countLimit = 256
        memory.totalCostLimit = 50 * 1024 * 1024
    }

    /// Synchronously fetches a memory hit (so the first view frame can draw immediately).
    func cachedImage(for url: URL) -> NSImage? {
        memory.object(forKey: url.absoluteString as NSString)
    }

    /// Loads asynchronously, with request coalescing and the memory cache.
    /// The returned `Task` is cancellable.
    func load(_ url: URL) -> Task<NSImage?, Never> {
        let key = url.absoluteString as NSString
        if let hit = memory.object(forKey: key) {
            return Task { hit }
        }
        let keyStr = url.absoluteString
        if let existing = inFlight[keyStr] { return existing }
        let task = Task<NSImage?, Never> { [self] in
            defer { self.inFlight[keyStr] = nil }
            do {
                let (data, response) = try await session.data(from: url)
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { return nil }
                guard !Task.isCancelled,
                      let decoded = await ArtworkImageDecoder.shared.decode(data, url: url),
                      !Task.isCancelled else { return nil }
                // Missing high-resolution YouTube thumbnails can return a tiny placeholder with HTTP 200.
                if url.host == "i.ytimg.com" || url.host == "img.youtube.com" {
                    if ["maxresdefault", "sddefault"].contains(url.deletingPathExtension().lastPathComponent),
                       decoded.width < 480 { return nil }
                }
                let img = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
                self.memory.setObject(img, forKey: key, cost: decoded.bytesPerRow * decoded.height)
                return img
            } catch {
                return nil
            }
        }
        inFlight[keyStr] = task
        return task
    }
}

/// Memory-cached image view replacing a bare `AsyncImage`.
/// Draws a memory hit on the first frame; otherwise loads asynchronously with
/// cancellation support, preferring the low-resolution URL.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    var lowResURL: URL? = nil
    var fallbackURLs: [URL] = []
    private let renderer: (Image) -> Content
    private let placeholderView: Placeholder

    @State private var image: NSImage? = nil
    @State private var loadedIdentity: String?

    private var requestIdentity: String {
        "\(url?.absoluteString ?? "nil")#\(lowResURL?.absoluteString ?? "nil")#\(fallbackURLs.map(\.absoluteString).joined(separator: "|"))"
    }

    init(url: URL?,
         lowResURL: URL? = nil,
         fallbackURLs: [URL] = [],
         @ViewBuilder content: @escaping (Image) -> Content,
         @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.lowResURL = lowResURL
        self.fallbackURLs = fallbackURLs
        self.renderer = content
        self.placeholderView = placeholder()
    }

    var body: some View {
        Group {
            if loadedIdentity == requestIdentity, let img = image {
                renderer(Image(nsImage: img))
            } else {
                placeholderView
            }
        }
        .task(id: requestIdentity) {
            await loadImage()
        }
    }

    @MainActor
    private func loadImage() async {
        let expectedIdentity = requestIdentity
        loadedIdentity = nil
        guard let url else {
            image = nil
            return
        }
        // Memory hit: available on the first frame.
        if let hit = ImageLoader.shared.cachedImage(for: url) {
            guard requestIdentity == expectedIdentity, !Task.isCancelled else { return }
            image = hit
            loadedIdentity = expectedIdentity
            PerfTrace.event("artwork.firstVisible")
            return
        }
        // Show the cached or fetched preview first, then upgrade without blanking it.
        if let low = lowResURL, low != url {
            let lowImg = await ImageLoader.shared.load(low).value
            if let lowImg,
               requestIdentity == expectedIdentity,
               !Task.isCancelled {
                image = lowImg
                loadedIdentity = expectedIdentity
                PerfTrace.event("artwork.firstVisible")
            }
        }
        for candidate in [url] + fallbackURLs {
            guard requestIdentity == expectedIdentity, !Task.isCancelled else { return }
            if let img = await ImageLoader.shared.load(candidate).value,
               requestIdentity == expectedIdentity, !Task.isCancelled {
                image = img
                loadedIdentity = expectedIdentity
                PerfTrace.event("artwork.firstVisible")
                return
            }
        }
    }
}

/// ImageIO produces decoded CGImages without touching AppKit on a worker.
/// Keep full thumbnail resolution; cap oversized sources at 2048 pixels for
/// Retina Now Playing while avoiding unbounded full-resolution allocations.
actor ArtworkImageDecoder {
    static let shared = ArtworkImageDecoder()

    func decode(_ data: Data, url: URL, maximumPixelSize: Int = 2048) -> CGImage? {
        guard maximumPixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        guard YouTubeThumbnail.isLetterboxed(url) else { return image }
        let aspect = Double(image.width) / Double(image.height)
        guard (1.22...1.48).contains(aspect) else { return image }
        let bar = Int((Double(image.height) * 0.125).rounded(.down))
        guard bar > 0, image.height - 2 * bar > 8 else { return image }
        return image.cropping(to: CGRect(x: 0, y: bar, width: image.width,
                                         height: image.height - 2 * bar)) ?? image
    }
}
