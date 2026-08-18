import SwiftUI
import AppKit

/// Phase D4 — 方形/16:9 发现卡片原语:封面 + 标题 + 副标题,横向滚动友好。
///
/// 统一本地专辑(artworkHash → ArtworkCache)与 YouTube(thumbnailURL → CachedAsyncImage)
/// 的卡片呈现。封面大小由 `size` 与 `aspect` 控制;点击经 `onTap`。
struct DiscoveryCard: View {
    enum Aspect { case square, wide169 }
    let title: String
    let subtitle: String?
    /// 本地封面缓存路径(优先于 remoteURL)。
    var artworkPath: URL? = nil
    /// 远程封面 URL(YouTube 缩略图 / Track.artworkUrl)。
    var remoteURL: URL? = nil
    /// 16:9 缩略图回退用低清首图;默认 nil → 直接用 remoteURL。
    var lowResURL: URL? = nil
    var size: CGFloat = 160
    var aspect: Aspect = .square
    var onTap: (() -> Void)? = nil
    var fallbackSymbol: String = "music.note"

    private var height: CGFloat {
        aspect == .square ? size : size * 9.0 / 16.0
    }

    var body: some View {
        Button {
            onTap?()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                artwork
                    .frame(width: size, height: height)
                    .clipped()
                    .cornerRadius(8)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(BrandColors.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(BrandColors.textSecondary)
                }
            }
            .frame(width: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(subtitle.map { "\(title) — \($0)" } ?? title)
    }

    @ViewBuilder
    private var artwork: some View {
        if let path = artworkPath,
           let img = NSImage(contentsOf: path) {
            Image(nsImage: img).resizable().scaledToFill()
        } else if let remoteURL {
            CachedAsyncImage(url: remoteURL, lowResURL: lowResURL,
                             content: { $0.resizable().scaledToFill() },
                             placeholder: { placeholder })
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Rectangle().fill(BrandColors.surface)
            .overlay(Image(systemName: fallbackSymbol).font(.title)
                .foregroundStyle(BrandColors.textSecondary.opacity(0.5)))
    }
}