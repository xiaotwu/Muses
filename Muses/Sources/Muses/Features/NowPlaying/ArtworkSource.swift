import SwiftUI
import AppKit

/// 封面来源:本地缓存文件 URL / 远程缩略图 URL(YouTube)/ 占位。
/// 解析只返回身份,不解码。解码由 `ArtworkView` + `ImageLoader` 负责。
enum ArtworkSource: Equatable, Sendable {
    case localFile(URL)
    case remote(URL)
    case placeholder

    static func localHash(_ hash: String?) -> ArtworkSource {
        guard let hash, !hash.isEmpty,
              let url = ArtworkCache.default.path(forHash: hash) else {
            return .placeholder
        }
        return .localFile(url)
    }

    /// 从 `TrackSnapshot` 解析封面来源。本地 hash 优先,其次 YouTube 缩略图,再次 artwork URL。
    static func resolve(for track: TrackSnapshot?) -> ArtworkSource {
        guard let track else { return .placeholder }
        let local = localHash(track.artworkHash)
        if case .localFile = local { return local }
        if let vid = track.youTubeId,
           let url = URL(string: "https://i.ytimg.com/vi/\(vid)/hqdefault.jpg") {
            return .remote(url)
        }
        if let urlStr = track.artworkUrl, let url = URL(string: urlStr) {
            return .remote(url)
        }
        return .placeholder
    }

    /// 从 `BrowsableAlbum` 解析封面:本地缓存 hash → 远程 URL(Cover Art/ytimg)→ 占位。
    static func resolve(for album: BrowsableAlbum) -> ArtworkSource {
        let local = localHash(album.artworkHash)
        if case .localFile = local { return local }
        if let urlStr = album.artworkURL, let url = URL(string: urlStr) {
            return .remote(url)
        }
        // 派生专辑无封面时,回退到首支 YouTube 曲目缩略图。
        if album.origin == .youTubeDerived, let vid = album.trackSnapshots.first?.youTubeId,
           let url = URL(string: "https://i.ytimg.com/vi/\(vid)/hqdefault.jpg") {
            return .remote(url)
        }
        return .placeholder
    }

    /// 从 `BrowsableArtist` 解析封面。
    static func resolve(for artist: BrowsableArtist) -> ArtworkSource {
        let local = localHash(artist.artworkHash)
        if case .localFile = local { return local }
        if let urlStr = artist.artworkURL, let url = URL(string: urlStr) {
            return .remote(url)
        }
        if artist.origin == .youTubeDerived, let vid = artist.trackSnapshots.first?.youTubeId,
           let url = URL(string: "https://i.ytimg.com/vi/\(vid)/hqdefault.jpg") {
            return .remote(url)
        }
        return .placeholder
    }

    /// Blocking decode for detached palette only. Never call from `body`.
    func loadNSImage() -> NSImage? {
        switch self {
        case .localFile(let url):
            return NSImage(contentsOf: url)
        case .remote(let url):
            guard let data = try? Data(contentsOf: url) else { return nil }
            return NSImage(data: data)
        case .placeholder:
            return nil
        }
    }
}

/// 渲染 `ArtworkSource` 的统一封面视图(方形,支持圆角与圆形裁切)。
struct ArtworkView: View {
    let source: ArtworkSource
    var cornerRadius: CGFloat = 12
    var glyphSize: CGFloat = 80
    var clipCircle: Bool = false
    var targetSize: CGFloat = 200

    var body: some View {
        Group {
            switch source {
            case .localFile(let url):
                LocalArtworkImage(url: url, targetSize: targetSize)
            case .remote(let url):
                CachedAsyncImage(
                    url: url,
                    content: { $0.resizable().scaledToFill() },
                    placeholder: { placeholder }
                )
            case .placeholder:
                placeholder
            }
        }
        .frame(width: targetSize, height: targetSize)
        .clipped()
        .clipShape(clipCircle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius)))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: clipCircle ? targetSize / 2 : cornerRadius)
            .fill(BrandColors.surface)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: glyphSize))
                    .foregroundStyle(BrandColors.textSecondary.opacity(0.5))
            )
    }
}

/// 本地封面:首帧读 `ImageLoader` 内存命中;未命中走有界解码,消失时取消,URL 变化丢弃结果。
private struct LocalArtworkImage: View {
    let url: URL
    let targetSize: CGFloat

    @State private var image: NSImage?
    @State private var loadedIdentity: String = ""
    @State private var loadTask: Task<NSImage?, Never>?

    private var identity: String {
        "\(url.absoluteString)#\(Int(targetSize.rounded()))"
    }

    var body: some View {
        Group {
            if let img = displayedImage {
                Image(nsImage: img).resizable().scaledToFill()
            }
        }
        .task(id: identity) {
            await loadIfNeeded()
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    private var displayedImage: NSImage? {
        if let hit = ImageLoader.shared.cachedImage(for: url, targetSize: targetSize) {
            return hit
        }
        return loadedIdentity == identity ? image : nil
    }

    @MainActor
    private func loadIfNeeded() async {
        if let hit = ImageLoader.shared.cachedImage(for: url, targetSize: targetSize) {
            image = hit
            loadedIdentity = identity
            return
        }
        let expected = identity
        let task = ImageLoader.shared.loadLocal(url: url, targetSize: targetSize)
        loadTask = task
        let img = await task.value
        loadTask = nil
        guard expected == identity, !Task.isCancelled else { return }
        image = img
        loadedIdentity = expected
    }
}
