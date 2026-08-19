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

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    ArtworkView(source: artwork, glyphSize: 40,
                                clipCircle: true, targetSize: size)
                    if isNowPlaying {
                        Image(systemName: "speaker.wave.2")
                            .foregroundStyle(BrandColors.textPrimary)
                    }
                }
                Text(name).font(.subheadline).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(BrandColors.textSecondary).lineLimit(1)
            }
            .frame(width: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name) — \(detail)")
    }
}
