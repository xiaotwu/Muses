import SwiftUI
import AppKit

/// 封面来源:本地缓存 `NSImage` / 远程缩略图 URL(YouTube)/ 占位。
/// 统一封装 Now Playing 中封面展示与渐变提取所需的取图逻辑。
enum ArtworkSource {
    case cached(NSImage)
    case remote(URL)
    case placeholder

    /// 从 `TrackSnapshot` 解析封面来源。本地优先 `ArtworkCache`,YouTube 用缩略图 URL。
    static func resolve(for track: TrackSnapshot?) -> ArtworkSource {
        guard let track else { return .placeholder }
        if let h = track.artworkHash, let p = ArtworkCache.default.path(forHash: h) {
            return .cached(NSImage(byReferencing: p))
        }
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
        if let h = album.artworkHash, let p = ArtworkCache.default.path(forHash: h) {
            return .cached(NSImage(byReferencing: p))
        }
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
        if let h = artist.artworkHash, let p = ArtworkCache.default.path(forHash: h) {
            return .cached(NSImage(byReferencing: p))
        }
        if let urlStr = artist.artworkURL, let url = URL(string: urlStr) {
            return .remote(url)
        }
        if artist.origin == .youTubeDerived, let vid = artist.trackSnapshots.first?.youTubeId,
           let url = URL(string: "https://i.ytimg.com/vi/\(vid)/hqdefault.jpg") {
            return .remote(url)
        }
        return .placeholder
    }

    /// 同步加载为 `NSImage`(`.cached` 直接返回;`.remote` 阻塞读取网络数据,仅在
    /// 后台任务中调用,用于渐变颜色提取)。
    var nsImage: NSImage? {
        switch self {
        case .cached(let img): return img
        case .remote(let url):
            if let data = try? Data(contentsOf: url) { return NSImage(data: data) }
            return nil
        case .placeholder: return nil
        }
    }
}

/// 渲染 `ArtworkSource` 的统一封面视图(方形,支持圆角与圆形裁切)。
struct ArtworkView: View {
    let source: ArtworkSource
    var cornerRadius: CGFloat = 12
    var glyphSize: CGFloat = 80

    var body: some View {
        Group {
            switch source {
            case .cached(let img):
                Image(nsImage: img).resizable().scaledToFill()
            case .remote(let url):
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() }
                    else { placeholder }
                }
            case .placeholder:
                placeholder
            }
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius).fill(BrandColors.surface)
            .overlay(Image(systemName: "music.note").font(.system(size: glyphSize))
                .foregroundStyle(BrandColors.textSecondary.opacity(0.5)))
    }
}