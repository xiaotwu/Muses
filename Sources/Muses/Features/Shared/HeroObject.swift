import SwiftUI

struct HeroObjectView: View {
    let title: String
    let subtitle: String
    var metadata: String? = nil
    let artwork: ArtworkSource
    var gradient: [Color] = []
    var isNowPlaying: Bool = false
    var showsHoverPlay: Bool = false
    var onOpen: () -> Void
    var onPlay: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 24) {
            Button(action: onOpen) {
                ArtworkView(
                    source: artwork,
                    cornerRadius: MusicObjectMetrics.albumCornerHero,
                    glyphSize: 40,
                    targetSize: MusicObjectMetrics.albumHero
                )
                .shadow(radius: 20)
                .overlay(alignment: .bottomLeading) { nowPlayingBadge }
            }
            .buttonStyle(.fullAreaPlain)
            .overlay(alignment: .bottomTrailing) { hoverPlayOverlay }
            .onHover { hovering = $0 }
            .scaleEffect(showsHoverPlay && hovering && !reduceMotion ? 1.06 : 1.0)
            .animation(MusesMotion.hoverAnimation(reduceMotion: reduceMotion), value: hovering)
            .accessibilityLabel("\(title) — \(subtitle)")

            VStack(alignment: .leading, spacing: 8) {
                Text(tr("FEATURED", "推荐"))
                    .font(MusesTypography.caption).fontWeight(.bold)
                    .foregroundStyle(BrandColors.textSecondary)
                    .tracking(1.5)

                Button(action: onOpen) {
                    Text(title)
                        .font(MusesTypography.pageTitle)
                        .foregroundStyle(BrandColors.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.fullAreaPlain)

                Text(subtitle)
                    .font(MusesTypography.song(size: 20))
                    .foregroundStyle(BrandColors.textSecondary)

                if let metadata {
                    Text(metadata)
                        .font(MusesTypography.subheadline)
                        .foregroundStyle(BrandColors.textSecondary)
                }

                Button(action: onPlay) {
                    Label(tr("Play", "播放"), systemImage: "play.fill")
                        .padding(.horizontal, 16).padding(.vertical, 8)
                }
                .musesAction(prominent: true)
                .tint(BrandColors.accent)
                .padding(.top, 4)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .background {
            if !gradient.isEmpty {
                LinearGradient(colors: gradient, startPoint: .top, endPoint: .center)
            }
        }
    }



    @ViewBuilder
    private var nowPlayingBadge: some View {
        if isNowPlaying {
            Image(systemName: "speaker.wave.2")
                .font(MusesTypography.caption)
                .padding(12)
                .foregroundStyle(BrandColors.textPrimary)
        }
    }

    @ViewBuilder
    private var hoverPlayOverlay: some View {
        if showsHoverPlay {
            HoverPlayButton(onPlay: onPlay)
                .padding(12)
                .opacity(hovering ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: MusesMotion.overlay), value: hovering)
                .allowsHitTesting(hovering)
        }
    }
}
