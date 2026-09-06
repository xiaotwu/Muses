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
        let totalHeight = size * 1.32
        let cardShape = RoundedRectangle(cornerRadius: 20, style: .continuous)

        Button(action: onSelect) {
            ZStack(alignment: .bottomLeading) {
                // Full-bleed artwork
                ArtworkView(
                    source: artwork,
                    cornerRadius: 0,
                    glyphSize: 48,
                    targetSize: size,
                    targetHeight: totalHeight,
                    presentation: .fill
                )
                .frame(width: size, height: totalHeight)
                .clipShape(cardShape)

                // Top-right floating frosted badge
                VStack {
                    HStack {
                        Spacer()
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 24, height: 24)
                            .overlay {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.75))
                            .shadow(color: .black.opacity(0.3), radius: 3)
                    }
                    .padding(.top, 10)
                    .padding(.trailing, 10)
                    Spacer()
                }

                // Bottom gradient scrim
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: Color.black.opacity(0.45), location: 0.40),
                        .init(color: Color.black.opacity(0.85), location: 0.75),
                        .init(color: Color.black.opacity(0.96), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: totalHeight * 0.58)
                .clipShape(cardShape)

                // Bottom content: Artist name, detail, and action row
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .shadow(color: .black.opacity(0.7), radius: 3, y: 1)

                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .shadow(color: .black.opacity(0.7), radius: 2, y: 1)

                    HStack(alignment: .center, spacing: 6) {
                        // Tag on left
                        HStack(spacing: 3) {
                            Image(systemName: isNowPlaying ? "waveform" : "person.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(isNowPlaying ? BrandColors.magenta : Color.white.opacity(0.8))
                            Text(tr("ARTIST", "艺术家"))
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.9))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.14), in: Capsule())

                        Spacer(minLength: 0)

                        // Action pill on right
                        Button(action: onPlay) {
                            HStack(spacing: 3) {
                                Image(systemName: isNowPlaying ? "speaker.wave.2.fill" : "play.fill")
                                    .font(.system(size: 8, weight: .bold))
                                Text(isNowPlaying ? tr("Playing", "播放中") : tr("Play", "播放"))
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                isNowPlaying || hovering
                                ? BrandColors.magenta
                                : Color.white.opacity(0.22),
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().stroke(Color.white.opacity(0.35), lineWidth: 0.75)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .frame(width: size, height: totalHeight)
            .background(BrandColors.surface)
            .clipShape(cardShape)
            .overlay {
                cardShape.stroke(
                    isNowPlaying
                        ? BrandColors.magenta.opacity(0.85)
                        : (hovering ? Color.white.opacity(0.28) : BrandColors.hairline),
                    lineWidth: (hovering || isNowPlaying) ? 1.5 : 1.0
                )
            }
            .shadow(
                color: .black.opacity(hovering ? 0.45 : 0.25),
                radius: hovering ? 16 : 8,
                y: hovering ? 8 : 4
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .offset(y: hovering && !reduceMotion ? -4 : 0)
        .animation(MusesMotion.hoverAnimation(reduceMotion: reduceMotion), value: hovering)
        .accessibilityLabel("\(name) — \(detail)")
    }
}
