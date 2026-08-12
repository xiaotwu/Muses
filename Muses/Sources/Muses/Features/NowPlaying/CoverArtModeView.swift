import SwiftUI
import AppKit

/// 巨大封面模式: 居中静止大圆角封面(480×480), 带 24pt 阴影。
/// 由 NowPlayingView 在 .cover 模式下展示。
struct CoverArtModeView: View {
    let artworkHash: String?

    var body: some View {
        artwork
            .frame(width: 480, height: 480)
            .cornerRadius(12)
            .shadow(radius: 24)
    }

    @ViewBuilder
    private var artwork: some View {
        if let h = artworkHash, let p = ArtworkCache.default.path(forHash: h) {
            Image(nsImage: NSImage(byReferencing: p))
                .resizable()
                .scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(BrandColors.surface)
                .overlay(Image(systemName: "music.note").font(.system(size: 80)))
        }
    }
}