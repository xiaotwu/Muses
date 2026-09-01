import SwiftUI

/// Tiny playback-identity child. Reads only `track?.id` and `isPlaying`.
/// Do not read `playback.state.position`. Album/artist collection identity
/// is resolved by the parent via `library.track(by:)` — not here.
struct NowPlayingMark: View {
    let itemID: UUID
    @Environment(PlaybackService.self) private var playback

    var body: some View {
        if playback.state.track?.id == itemID {
            Image(systemName: playback.state.isPlaying ? "speaker.wave.2" : "play.fill")
                .foregroundStyle(BrandColors.textPrimary)
                .accessibilityLabel(tr("Now Playing", "正在播放"))
        }
    }
}
