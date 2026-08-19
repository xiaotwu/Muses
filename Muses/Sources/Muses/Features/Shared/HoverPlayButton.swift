import SwiftUI

/// Circular Play control that sits on artwork (chrome on the object, not a glass card).
struct HoverPlayButton: View {
    var onPlay: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Button(action: onPlay) {
            Image(systemName: "play.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(BrandColors.textPrimary)
                .frame(width: 30, height: 30)
                .background(
                    Color.black.opacity(reduceTransparency ? 0.75 : 0.45),
                    in: Circle()
                )
                .musesGlass(in: Circle())
        }
        .buttonStyle(.plain)
        .help(tr("Play", "播放"))
        .accessibilityLabel(tr("Play", "播放"))
    }
}
