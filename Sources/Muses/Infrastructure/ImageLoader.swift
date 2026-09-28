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

    private let memory: NSCache<NSString, NSImage> = .init()
    /// In-flight requests (URL -> Task), used for coalescing.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    init() {
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
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled,
                      let decoded = await ArtworkImageDecoder.shared.decode(data, url: url),
                      !Task.isCancelled else { return nil }
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
    private let renderer: (Image) -> Content
    private let placeholderView: Placeholder

    @State private var image: NSImage? = nil
    @State private var loadedIdentity: String?

    private var requestIdentity: String {
        "\(url?.absoluteString ?? "nil")#\(lowResURL?.absoluteString ?? "nil")"
    }

    init(url: URL?,
         lowResURL: URL? = nil,
         @ViewBuilder content: @escaping (Image) -> Content,
         @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.lowResURL = lowResURL
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
        // Low-resolution first: if provided and not cached, load the low-res
        // image first, then upgrade.
        if let low = lowResURL, low != url,
           ImageLoader.shared.cachedImage(for: low) == nil {
            let lowTask = ImageLoader.shared.load(low)
            if let lowImg = await lowTask.value,
               requestIdentity == expectedIdentity,
               !Task.isCancelled {
                image = lowImg
                loadedIdentity = expectedIdentity
                PerfTrace.event("artwork.firstVisible")
            }
        }
        let task = ImageLoader.shared.load(url)
        if let img = await task.value,
           requestIdentity == expectedIdentity,
           !Task.isCancelled {
            image = img
            loadedIdentity = expectedIdentity
            PerfTrace.event("artwork.firstVisible")
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
