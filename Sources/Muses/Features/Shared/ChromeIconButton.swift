import SwiftUI

/// Opaque artwork-overlay badge. Content-layer only: no material and no glass.
enum ContentBadgeStyle {
    static let usesMaterial = false
    static let usesOpaqueScrim = true
    static let fill = Color.black.opacity(0.58)
    static let stroke = Color.white.opacity(0.28)
    static let lineWidth: CGFloat = 1
}

struct ContentScrimCircle<Content: View>: View {
    var size: CGFloat = 24
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: size, height: size)
            .background(ContentBadgeStyle.fill, in: Circle())
            .overlay(Circle().stroke(ContentBadgeStyle.stroke, lineWidth: ContentBadgeStyle.lineWidth))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

/// Round chrome control that stays readable on light, dark, and Reduce Transparency.
/// Shared interactive glass with accessible opaque fallback.
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
                .musesGlass(in: Capsule(), role: .compactControl)
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

/// Keep compact surface actions icon-only without shrinking their pointer target.
struct ActionIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label(configuration)
            .labelStyle(.iconOnly)
            .frame(minWidth: 28, minHeight: 28)
    }
}
