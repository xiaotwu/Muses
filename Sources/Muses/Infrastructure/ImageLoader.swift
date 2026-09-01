import Foundation
import AppKit
import SwiftUI

/// Shared image loader: memory cache + request coalescing + low-resolution-first
/// + cancellation of offscreen loads.
///
/// - Memory: `NSCache<NSString, NSImage>` (the system evicts automatically under
///   memory pressure).
/// - Coalescing: concurrent requests for the same URL trigger a single
///   network/disk read; the rest await the same task.
/// - Low-resolution first: YouTube `hqdefault` (<200px) is shown as soon as it
///   arrives, then upgraded when needed.
/// - Cancellation: the task returned by `load(_:)` is cancelled in the view's
///   `.onDisappear`, so offscreen fetches stop.
///
/// The disk layer relies on the system's shared `URLCache` (same as AsyncImage);
/// this class only adds the memory cache, coalescing, and cancellation.
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
            defer { Task { @MainActor in self.inFlight[keyStr] = nil } }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled, let decoded = NSImage(data: data) else { return nil }
                let img = YouTubeThumbnail.cropLetterboxIfNeeded(decoded, url: url)
                // Estimated cost to help NSCache make eviction decisions.
                let cost = data.count
                self.memory.setObject(img, forKey: key, cost: cost)
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
struct CachedAsyncImage: View {
    let url: URL?
    var lowResURL: URL? = nil
    private let renderer: (NSImage) -> AnyView
    private let placeholderView: AnyView

    @State private var image: NSImage? = nil
    @State private var loadedIdentity: String?

    private var requestIdentity: String {
        "\(url?.absoluteString ?? "nil")#\(lowResURL?.absoluteString ?? "nil")"
    }

    init(url: URL?,
         lowResURL: URL? = nil,
         content: @escaping (Image) -> some View,
         placeholder: @escaping () -> some View) {
        self.url = url
        self.lowResURL = lowResURL
        self.renderer = { ns in AnyView(content(Image(nsImage: ns))) }
        self.placeholderView = AnyView(placeholder())
    }

    var body: some View {
        Group {
            if loadedIdentity == requestIdentity, let img = image {
                renderer(img)
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
