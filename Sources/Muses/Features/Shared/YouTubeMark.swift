import SwiftUI

/// Monochrome YouTube mark that adapts to the surrounding appearance.
///
/// Use only where the control opens, jumps to, or identifies YouTube.
/// Playback actions must use `play.fill` / `pause.fill`, never this mark.
struct YouTubeMark: View {
    var size: CGFloat = 18
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(colorScheme == .dark ? Color.white : Color.black)
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                .offset(x: size * 0.04)
        }
        .frame(width: size * 1.28, height: size * 0.92)
        .accessibilityLabel("YouTube")
    }
}
