import SwiftUI
import AppKit

/// 巨大封面模式: 居中静止大圆角封面(480×480), 带 24pt 阴影。
/// 宽路径由 live-cover host 展示;窄窗/skip-morph 仍由 NowPlayingView 内嵌。
struct CoverArtModeView: View {
    let source: ArtworkSource

    var body: some View {
        ArtworkView(source: source, cornerRadius: 12, glyphSize: 80, targetSize: 480)
            .frame(width: 480, height: 480)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(radius: 24)
    }
}