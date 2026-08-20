import SwiftUI

/// 16:9 Apple Music Web editorial tile: eyebrow + title + subtitle above a landscape image.
struct EditorialCard: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let artwork: ArtworkSource
    var width: CGFloat = AppleMusicTokens.editorialWidth
    var imageHeight: CGFloat = AppleMusicTokens.editorialHeight
    var onOpen: () -> Void
    var onPlay: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(BrandColors.textSecondary)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(BrandColors.textPrimary)
                .lineLimit(2)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(BrandColors.textSecondary)
                .lineLimit(2)
                .frame(height: 34, alignment: .top)
            Button(action: onOpen) {
                ArtworkView(
                    source: artwork,
                    cornerRadius: 0,
                    glyphSize: 28,
                    targetSize: width
                )
                .frame(width: width, height: imageHeight, alignment: .center)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: AppleMusicTokens.cardCorner, style: .continuous))
            }
            .buttonStyle(.plain)
            .overlay(alignment: .bottomTrailing) {
                if hovering {
                    HoverPlayButton(onPlay: onPlay)
                        .padding(10)
                }
            }
            .onHover { hovering = $0 }
            .animation(MusesMotion.hoverAnimation(reduceMotion: reduceMotion), value: hovering)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(eyebrow), \(title), \(subtitle)")
    }
}
