import SwiftUI

/// Round chrome control that stays readable on light, dark, and Reduce Transparency.
/// Solid `surface` fill + hairline; no translucent glass (those vanish on artwork).
struct ChromeIconButton: View {
    let systemName: String
    var help: String? = nil
    var accessibility: String
    var action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(BrandColors.textPrimary)
                .frame(width: 28, height: 28)
                .background(isHovered ? BrandColors.surface.opacity(0.85) : BrandColors.surface, in: Circle())
                .overlay(Circle().stroke(BrandColors.textPrimary.opacity(isHovered ? 0.45 : 0.28), lineWidth: 1))
                .scaleEffect(isHovered && !reduceMotion ? 1.05 : 1.0)
                .offset(y: isHovered && !reduceMotion ? -1 : 0)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(MusesMotion.hoverAnimation(reduceMotion: reduceMotion), value: isHovered)
        .help(help ?? accessibility)
        .accessibilityLabel(accessibility)
    }
}
