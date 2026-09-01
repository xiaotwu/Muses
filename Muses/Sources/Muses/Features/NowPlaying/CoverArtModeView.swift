import SwiftUI
import AppKit

/// 巨大封面模式: 居中静止大圆角封面(480×480), 带 24pt 阴影。
/// 宽路径由 live-cover host 展示;窄窗/skip-morph 仍由 NowPlayingView 内嵌。
struct CoverArtModeView: View {
    let source: ArtworkSource
    var size: CGFloat = 480

    var body: some View {
        ArtworkView(source: source, cornerRadius: 12, glyphSize: min(80, size * 0.17), targetSize: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(radius: 24)
    }
}