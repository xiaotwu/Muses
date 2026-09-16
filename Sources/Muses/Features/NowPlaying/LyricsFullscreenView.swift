import SwiftUI

/// All fullscreen modes share document identity, enrichment, cancellation,
/// accessibility and timing with the drawer and Now Playing lyrics.
struct LyricsFullscreenView: View {
    let mode: NowPlayingLyricsMode
    var body: some View {
        LyricsView(layout: .fullscreen, showsCurrentLineOnly: mode == .minimal)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
