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
    var showsHoverPlay: Bool = false
    var onSelect: () -> Void
    var onPlay: () -> Void

    var body: some View {
        Button(action: {
            switch role {
            case .browse: onSelect()
            case .play: onPlay()
            }
        }) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    ArtworkView(source: artwork, cornerRadius: cornerRadius,
                                glyphSize: size > 180 ? 40 : 28, targetSize: size)
                    if isNowPlaying {
                        Image(systemName: "speaker.wave.2")
                            .font(.caption)
                            .padding(6)
                            .foregroundStyle(BrandColors.textPrimary)
                    }
                }
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
        .accessibilityLabel("\(title) — \(subtitle)")
    }
}
