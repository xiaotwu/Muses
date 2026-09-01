import SwiftUI

struct ArtistObjectView: View {
    let name: String
    let detail: String
    let artwork: ArtworkSource
    var size: CGFloat = MusicObjectMetrics.artistGrid
    var isNowPlaying: Bool = false
    var showsHoverPlay: Bool = false
    var onSelect: () -> Void
    var onPlay: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(source: artwork, glyphSize: 40,
                            clipCircle: true, targetSize: size)
                    .overlay(alignment: .bottom) { nowPlayingBadge }
                Text(name).font(.subheadline).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(BrandColors.textSecondary).lineLimit(1)
            }
            .frame(width: size)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            hoverPlayOverlay
                .frame(width: size, height: size, alignment: .bottom)
        }
        .onHover { hovering = $0 }
        .scaleEffect(showsHoverPlay && hovering && !reduceMotion ? 1.08 : 1.0)
        .animation(MusesMotion.hoverAnimation(reduceMotion: reduceMotion), value: hovering)
        .accessibilityLabel("\(name) — \(detail)")
    }



    @ViewBuilder
    private var nowPlayingBadge: some View {
        if isNowPlaying {
            Image(systemName: "speaker.wave.2")
                .font(.caption)
                .padding(.bottom, 10)
                .foregroundStyle(BrandColors.textPrimary)
        }
    }

    @ViewBuilder
    private var hoverPlayOverlay: some View {
        if showsHoverPlay {
            HoverPlayButton(onPlay: onPlay)
                .padding(.bottom, 10)
                .opacity(hovering ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: MusesMotion.overlay), value: hovering)
                .allowsHitTesting(hovering)
        }
    }
}
