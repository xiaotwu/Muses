import SwiftUI

enum AlbumObjectRole {
    case browse
    case play
}

struct AlbumObjectView: View {
    let title: String
    let subtitle: String
    let artwork: ArtworkSource
    var size: CGFloat = MusicObjectMetrics.albumGrid
    var cornerRadius: CGFloat = MusicObjectMetrics.albumCornerRail
    var role: AlbumObjectRole = .browse
    var isNowPlaying: Bool = false
    /// Snap-level identity for `.play` rails. Compared inside `NowPlayingMark`,
    /// not by the parent `ForEach` reading `playback.state`.
    var nowPlayingID: UUID? = nil
    var showsHoverPlay: Bool = false
    var onSelect: () -> Void
    var onPlay: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: primaryAction) {
            VStack(alignment: .leading, spacing: 8) {
                artworkStack
                Text(title)
                    .font(size >= 200 ? .subheadline : .caption)
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(BrandColors.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: size)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .offset(y: liftOffset)
        .animation(MusesMotion.hoverAnimation(reduceMotion: reduceMotion), value: hovering)
        .accessibilityLabel("\(title) — \(subtitle)")
    }

    private var primaryAction: () -> Void {
        switch role {
        case .browse: onSelect
        case .play: onPlay
        }
    }

    private var liftOffset: CGFloat {
        (showsHoverPlay && hovering && !reduceMotion) ? -MusicObjectMetrics.hoverLift : 0
    }

    private var artworkStack: some View {
        ArtworkView(source: artwork, cornerRadius: cornerRadius,
                    glyphSize: size > 180 ? 40 : 28, targetSize: size)
            .overlay(alignment: .bottomLeading) { nowPlayingBadge }
            .overlay(alignment: .bottomTrailing) { hoverPlayOverlay }
    }

    @ViewBuilder
    private var nowPlayingBadge: some View {
        if let nowPlayingID {
            NowPlayingMark(itemID: nowPlayingID)
                .font(.caption)
                .padding(6)
        } else if isNowPlaying {
            Image(systemName: "speaker.wave.2")
                .font(.caption)
                .padding(6)
                .foregroundStyle(BrandColors.textPrimary)
        }
    }

    @ViewBuilder
    private var hoverPlayOverlay: some View {
        if showsHoverPlay {
            HoverPlayButton(onPlay: onPlay)
                .padding(8)
                .opacity(hovering ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: MusesMotion.overlay), value: hovering)
                .allowsHitTesting(hovering)
        }
    }
}
