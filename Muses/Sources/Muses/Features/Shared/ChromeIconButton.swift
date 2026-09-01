import SwiftUI

/// Round chrome control that stays readable on light, dark, and Reduce Transparency.
/// Solid `surface` fill + hairline; no translucent glass (those vanish on artwork).
struct ChromeIconButton: View {
    let systemName: String
    var help: String? = nil
    var accessibility: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(BrandColors.textPrimary)
                .frame(width: 28, height: 28)
                .background(BrandColors.surface, in: Circle())
                .overlay(Circle().stroke(BrandColors.textPrimary.opacity(0.28), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help ?? accessibility)
        .accessibilityLabel(accessibility)
    }
}
