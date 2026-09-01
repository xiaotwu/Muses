import SwiftUI
import AppKit

/// Artwork source: remote YouTube/catalog image or placeholder.
/// 解析只返回身份,不解码。解码由 `ArtworkView` + `ImageLoader` 负责。
enum ArtworkSource: Equatable, Sendable {
    case remote(URL)
    case placeholder

    var identity: String {
        switch self {
        case .remote(let url): "remote:\(url.absoluteString)"
        case .placeholder: "placeholder"
        }
    }

    /// Resolve a track's remote metadata image, then its YouTube thumbnail.
    static func resolve(for track: TrackSnapshot?) -> ArtworkSource {
        guard let track else { return .placeholder }
        return resolve(remoteURL: track.artworkUrl, youTubeId: track.youTubeId)
    }

    static func resolve(for track: Track) -> ArtworkSource {
        resolve(for: TrackSnapshot(from: track))
    }

    static func resolve(remoteURL: String?, youTubeId: String? = nil) -> ArtworkSource {
        if let urlStr = remoteURL, let url = URL(string: urlStr) {
            return .remote(url)
        }
        if let vid = youTubeId, let url = YouTubeThumbnail.url(videoId: vid) {
            return .remote(url)
        }
        return .placeholder
    }

    /// Blocking decode for detached palette only. Never call from `body`.
    func loadNSImage() -> NSImage? {
        switch self {
        case .remote(let url):
            guard let data = try? Data(contentsOf: url), let img = NSImage(data: data) else { return nil }
            return YouTubeThumbnail.cropLetterboxIfNeeded(img, url: url)
        case .placeholder:
            return nil
        }
    }
}

enum ArtworkPresentation: String, Equatable, Sendable {
    case fill
    case fitOnAmbient
}

/// Unified artwork rendering. Browsing defaults to square fill; selected
/// Hero/Home surfaces can opt into complete artwork over an ambient wash.
struct ArtworkView: View {
    let source: ArtworkSource
    var cornerRadius: CGFloat = 12
    var glyphSize: CGFloat = 80
    var clipCircle: Bool = false
    var targetSize: CGFloat = 200
    /// Optional non-square presentation height. Decoding still uses the width
    /// as its bounded cache target, while layout can preserve wide artwork in
    /// editorial and playlist-card media regions.
    var targetHeight: CGFloat? = nil
    var presentation: ArtworkPresentation = .fill

    private var resolvedHeight: CGFloat { targetHeight ?? targetSize }

    var body: some View {
        Group {
            switch source {
            case .remote(let url):
                CachedAsyncImage(
                    url: url,
                    content: {
                        ResolvedArtworkImage(
                            image: $0,
                            presentation: presentation,
                            targetSize: targetSize
                        )
                    },
                    placeholder: { placeholder }
                )
            case .placeholder:
                placeholder
            }
        }
        .frame(width: targetSize, height: resolvedHeight)
        .clipped()
        .clipShape(clipCircle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius)))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: clipCircle ? min(targetSize, resolvedHeight) / 2 : cornerRadius)
            .fill(BrandColors.surface)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: glyphSize))
                    .foregroundStyle(BrandColors.textSecondary.opacity(0.5))
            )
    }
}

/// Artwork-driven ambient fill for non-square YouTube images. The crisp
/// foreground always keeps its complete aspect ratio while the same decoded
/// image supplies a restrained blurred wash behind it.
private struct ResolvedArtworkImage: View {
    let image: Image
    let presentation: ArtworkPresentation
    let targetSize: CGFloat

    @ViewBuilder
    var body: some View {
        switch presentation {
        case .fill:
            image
                .resizable()
                .scaledToFill()
        case .fitOnAmbient:
            ZStack {
                image
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(1.18)
                    .blur(radius: max(12, targetSize * 0.075), opaque: true)
                    .saturation(1.12)
                    .brightness(-0.12)

                LinearGradient(
                    colors: [
                        BrandColors.background.opacity(0.08),
                        Color.clear,
                        BrandColors.background.opacity(0.16)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                image
                    .resizable()
                    .scaledToFit()
                    .saturation(0.96)
            }
        }
    }
}
