import SwiftUI

struct HeroObjectView: View {
    let title: String
    let subtitle: String
    var metadata: String? = nil
    let artwork: ArtworkSource
    var gradient: [Color] = []
    var onOpen: () -> Void
    var onPlay: () -> Void

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
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) — \(subtitle)")

            VStack(alignment: .leading, spacing: 8) {
                Text(tr("FEATURED", "推荐"))
                    .font(.caption).fontWeight(.bold)
                    .foregroundStyle(BrandColors.textSecondary)
                    .tracking(1.5)

                Button(action: onOpen) {
                    Text(title)
                        .font(.largeTitle).fontWeight(.bold)
                        .foregroundStyle(BrandColors.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)

                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(BrandColors.textSecondary)

                if let metadata {
                    Text(metadata)
                        .font(.subheadline)
                        .foregroundStyle(BrandColors.textSecondary)
                }

                Button(action: onPlay) {
                    Label(tr("Play", "播放"), systemImage: "play.fill")
                        .padding(.horizontal, 16).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColors.magenta)
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
}
