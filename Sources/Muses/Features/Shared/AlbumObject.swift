import SwiftUI

enum AlbumObjectRole {
    case browse
    case play
}

enum AlbumObjectStyle {
    case standard
    case home
}

struct AlbumObjectView: View {
    let title: String
    let subtitle: String
    let artwork: ArtworkSource
    var size: CGFloat = MusicObjectMetrics.albumGrid
    var cornerRadius: CGFloat = MusicObjectMetrics.albumCornerRail
    var role: AlbumObjectRole = .browse
    var style: AlbumObjectStyle = .standard
    var artworkHeight: CGFloat? = nil
    var footerHeight: CGFloat? = nil
    var homeCornerRadius: CGFloat? = nil
    var hoverLift: CGFloat? = nil
    var pressedScale: CGFloat = 1
    var isYouTube = false
    var isNowPlaying: Bool = false
    /// Snap-level identity for `.play` rails. Compared inside `NowPlayingMark`,
    /// not by the parent `ForEach` reading `playback.state`.
    var nowPlayingID: UUID? = nil
    var showsHoverPlay: Bool = false
    var onSelect: () -> Void
    var onPlay: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    private var resolvedArtworkHeight: CGFloat { artworkHeight ?? size }
    private var resolvedFooterHeight: CGFloat { footerHeight ?? HomeMediaCardMetrics.footerHeight }
    private var resolvedHomeCornerRadius: CGFloat { homeCornerRadius ?? AppleMusicTokens.cardCorner }
    private var resolvedHoverLift: CGFloat { hoverLift ?? 3 }
    private var homeShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: resolvedHomeCornerRadius, style: .continuous)
    }

    var body: some View {
        Button(action: primaryAction) {
            objectContent
        }
        .buttonStyle(AlbumObjectPressStyle(scale: pressedScale, reduceMotion: reduceMotion))
        .overlay(alignment: .topLeading) {
            hoverPlayOverlay
                .frame(width: size, height: resolvedArtworkHeight, alignment: .bottomTrailing)
        }
        .onHover { hovering = $0 }
        .offset(y: style == .home && hovering && !reduceMotion ? -resolvedHoverLift : 0)
        .zIndex(hovering ? 2 : 0)
        .animation(MusesMotion.hoverAnimation(reduceMotion: reduceMotion), value: hovering)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .overlay {
            if style == .home, focused {
                homeShape
                    .stroke(Color.white.opacity(0.92), lineWidth: 2)
                    .shadow(color: Color.white.opacity(0.34), radius: 6)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel("\(title) — \(subtitle)")
        .accessibilityAction(named: Text(
            role == .play
                ? tr("Play \(title)", "播放 \(title)")
                : tr("Open \(title)", "打开 \(title)"))) {
            primaryAction()
        }
    }

    private var primaryAction: () -> Void {
        switch role {
        case .browse: onSelect
        case .play: onPlay
        }
    }

    @ViewBuilder
    private var objectContent: some View {
        switch style {
        case .standard:
            VStack(alignment: .leading, spacing: 8) {
                artworkStack
                Text(title)
                    .font(size >= 160 ? .subheadline : .caption)
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(size >= 160 ? .caption : .caption2)
                    .foregroundStyle(BrandColors.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: size)
        case .home:
            VStack(alignment: .leading, spacing: 0) {
                artworkStack

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(size >= 160 ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
                        .foregroundStyle(BrandColors.textPrimary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Text(subtitle)
                        .font(size >= 160 ? .caption : .caption2)
                        .foregroundStyle(BrandColors.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 12)
                .padding(.top, 9)
                .frame(
                    maxWidth: .infinity,
                    minHeight: resolvedFooterHeight,
                    maxHeight: resolvedFooterHeight,
                    alignment: .topLeading
                )
                .background(BrandColors.surface)
            }
            .frame(width: size, height: resolvedArtworkHeight + resolvedFooterHeight)
            .background(BrandColors.surface)
            .clipShape(homeShape)
            .overlay(homeShape.stroke(Color.white.opacity(0.10), lineWidth: 1))
        }
    }

    private var artworkStack: some View {
        ArtworkView(
            source: artwork,
            cornerRadius: style == .home ? 0 : cornerRadius,
            glyphSize: size > 180 ? 40 : 28,
            targetSize: size,
            targetHeight: resolvedArtworkHeight,
            presentation: style == .home ? .fitOnAmbient : .fill
        )
            .scaleEffect(
                style == .standard && showsHoverPlay && hovering && !reduceMotion ? 1.08 : 1.0
            )
            .shadow(radius: style == .standard && hovering && showsHoverPlay ? 18 : 0)
            .overlay(alignment: .bottomLeading) { nowPlayingBadge }
            .overlay(alignment: .topTrailing) { sourceBadge }
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
        if showsHoverPlay, hovering {
            HoverPlayButton(onPlay: onPlay)
                .padding(8)
                .transition(.opacity)
                .focusable(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var sourceBadge: some View {
        if isYouTube {
            YouTubeMark(size: 12)
                .padding(.horizontal, 7)
                .frame(height: 24)
                .musesGlass(cornerRadius: 7, role: .persistentChrome)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(BrandColors.textPrimary.opacity(0.16), lineWidth: 1)
                }
                .padding(8)
                .help(tr("YouTube playlist", "YouTube 歌单"))
                .accessibilityLabel(tr("YouTube playlist", "YouTube 歌单"))
        }
    }
}

private struct AlbumObjectPressStyle: ButtonStyle {
    let scale: CGFloat
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: MusesMotion.hover),
                value: configuration.isPressed
            )
    }
}
