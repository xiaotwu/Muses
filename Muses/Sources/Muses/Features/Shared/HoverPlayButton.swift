import SwiftUI

/// Circular Play control that sits on artwork (chrome on the object, not a glass card).
struct HoverPlayButton: View {
    var onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            Image(systemName: "play.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(BrandColors.magenta, in: Circle())
        }
        .buttonStyle(.plain)
        .help(tr("Play", "播放"))
        .accessibilityLabel(tr("Play", "播放"))
    }
}
