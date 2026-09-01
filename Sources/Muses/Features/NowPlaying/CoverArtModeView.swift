import SwiftUI
import AppKit

/// Large cover mode: centered, static, large rounded-corner cover (480x480) with a 24pt shadow.
/// Shown by the live-cover host on the wide layout; the narrow window / skip-morph stays inline in NowPlayingView.
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