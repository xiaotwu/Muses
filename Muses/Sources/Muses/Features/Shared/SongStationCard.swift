import SwiftUI

enum HomeMediaCardMetrics {
    static let footerHeight: CGFloat = 72
}

enum SongStationCardStyle {
    case portraitOverlay
    case home
}

/// Made-for-You station tile. Home uses an aligned media/footer card while
/// other grids retain the established portrait-overlay presentation.
struct SongStationCard: View {
    let title: String
    let subtitle: String
    let artwork: ArtworkSource
    var isYouTube: Bool = false
    var nowPlayingID: UUID? = nil
    var style: SongStationCardStyle = .portraitOverlay
    var onOpen: () -> Void
    var onPlay: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AppleMusicTokens.cardCorner, style: .continuous)
        Group {
            switch style {
            case .portraitOverlay:
                cardButton {
                    portraitContent(shape: shape)
                }
                .aspectRatio(SongGridMetrics.aspect, contentMode: .fit)
            case .home:
                cardButton {
                    homeContent(shape: shape)
                }
                .frame(width: SongGridMetrics.maxCard)
                .offset(y: hovering && !reduceMotion ? -3 : 0)
            }
        }
        .onHover { hovering = $0 }
        .animation(MusesMotion.hoverAnimation(reduceMotion: reduceMotion), value: hovering)
        .accessibilityLabel("\(title) — \(subtitle)")
    }

    private func cardButton<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: onOpen) {
            content()
        }
        .buttonStyle(.plain)
    }

    private func portraitContent(
        shape: RoundedRectangle
    ) -> some View {
        Color.clear
            .aspectRatio(SongGridMetrics.aspect, contentMode: .fit)
            .overlay {
                ZStack(alignment: .bottomLeading) {
                    ArtworkView(
                        source: artwork,
                        cornerRadius: 0,
                        glyphSize: 28,
                        targetSize: SongGridMetrics.maxCard / SongGridMetrics.aspect
                    )
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.0),
                            Color.black.opacity(0.15),
                            Color.black.opacity(0.78)
                        ],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .truncationMode(.tail)
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(12)
                }
                .overlay(alignment: .topTrailing) { youTubeBadge }
            }
            .overlay(alignment: .bottomTrailing) { hoverPlay(padding: 10) }
            .clipShape(shape)
            .contentShape(shape)
    }

    private func homeContent(
        shape: RoundedRectangle
    ) -> some View {
        VStack(spacing: 0) {
            ArtworkView(
                source: artwork,
                cornerRadius: 0,
                glyphSize: 28,
                targetSize: SongGridMetrics.maxCard,
                presentation: .fitOnAmbient
            )
            .overlay(alignment: .topTrailing) { youTubeBadge }
            .overlay(alignment: .bottomLeading) { nowPlayingBadge }
            .overlay(alignment: .bottomTrailing) { hoverPlay(padding: 9) }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(BrandColors.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .frame(maxWidth: .infinity, minHeight: HomeMediaCardMetrics.footerHeight,
                   maxHeight: HomeMediaCardMetrics.footerHeight, alignment: .topLeading)
            .background(BrandColors.surface)
        }
        .frame(width: SongGridMetrics.maxCard)
        .background(BrandColors.surface)
        .clipShape(shape)
        .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 1))
        .contentShape(shape)
    }

    @ViewBuilder
    private var youTubeBadge: some View {
        if isYouTube {
            YouTubeMark(size: 16)
                .padding(10)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var nowPlayingBadge: some View {
        if let nowPlayingID {
            NowPlayingMark(itemID: nowPlayingID)
                .font(.caption)
                .padding(7)
        }
    }

    @ViewBuilder
    private func hoverPlay(padding: CGFloat) -> some View {
        if hovering {
            HoverPlayButton(onPlay: onPlay)
                .padding(padding)
        }
    }
}

struct SongStationGrid: View {
    let snaps: [TrackSnapshot]
    var playlists: [Playlist] = []
    var onPlay: (TrackSnapshot) -> Void
    var onRemove: ((TrackSnapshot) -> Void)? = nil

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: SongGridMetrics.minCard,
                                               maximum: SongGridMetrics.maxCard),
                                     spacing: SongGridMetrics.spacing)],
                  spacing: SongGridMetrics.spacing) {
            ForEach(snaps) { snap in
                SongStationCard(
                    title: snap.title,
                    subtitle: snap.artist,
                    artwork: ArtworkSource.resolve(for: snap),
                    isYouTube: !snap.youTubeId.isEmpty,
                    nowPlayingID: snap.id,
                    onOpen: { onPlay(snap) },
                    onPlay: { onPlay(snap) }
                )
                .trackContextMenu(
                    snapshot: snap,
                    playlists: playlists,
                    onPlay: { onPlay(snap) },
                    onRemoveFromContainer: onRemove.map { handler in { handler(snap) } }
                )
            }
        }
        .padding(.horizontal, AppleMusicTokens.contentPaddingX)
        .padding(.bottom, OverlayChromeMetrics.scrollBottomInset)
    }
}
