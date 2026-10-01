import SwiftUI

/// Opaque artwork-overlay badge. Content-layer only: no material and no glass.
enum ContentBadgeStyle {
    static let usesMaterial = false
    static let usesOpaqueScrim = true
    static let fill = Color.black.opacity(0.58)
    static let stroke = Color.white.opacity(0.28)
    static let lineWidth: CGFloat = 1
}

/// Compact artwork action using the same circle as page chrome.
struct ContentScrimCircle<Content: View>: View {
    var size: CGFloat = 28
    @ViewBuilder var content: Content

    var body: some View {
        content.chromeActionCircle(diameter: size)
            .environment(\.colorScheme, .dark)
    }
}

/// Round chrome control that stays readable on light, dark, and Reduce Transparency.
/// Shared interactive glass with accessible opaque fallback.
struct ChromeIconButton: View {
    let systemName: String
    var help: String? = nil
    var accessibility: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).chromeActionCircle(prominent: systemName == "play.fill")
        }
        .buttonStyle(.fullAreaPlain)
        .help(help ?? accessibility)
        .accessibilityLabel(accessibility)
    }
}

/// Shared circle metrics for page actions, menus, and links. The glyph owns no
/// padding or background of its own; the entire visible circle is interactive.
enum ChromeActionMetrics {
    static let diameter: CGFloat = 32
    static let glyphSize: CGFloat = 14
}

private struct ChromeActionCircle: ViewModifier {
    var diameter: CGFloat
    var prominent = false
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        content
            .font(MusesTypography.system(size: ChromeActionMetrics.glyphSize, weight: .semibold))
            .foregroundStyle(prominent ? (colorScheme == .dark ? Color.black.opacity(0.88) : Color.white) : BrandColors.textPrimary)
            .frame(width: diameter, height: diameter, alignment: .center)
            .contentShape(Circle())
            .background(prominent ? BrandColors.accent : .clear, in: Circle())
            .modifier(CompactChromeSurface())
    }
}

extension View {
    func chromeActionCircle(diameter: CGFloat = ChromeActionMetrics.diameter, prominent: Bool = false) -> some View {
        modifier(ChromeActionCircle(diameter: diameter, prominent: prominent))
    }
}

struct ChromeIconMenu<Items: View>: View {
    let systemName: String
    let title: String
    var diameter: CGFloat = ChromeActionMetrics.diameter
    var foreground: Color = BrandColors.textPrimary
    @ViewBuilder var items: () -> Items

    var body: some View {
        Menu(content: items) {
            Color.clear.frame(width: diameter, height: diameter)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: diameter, height: diameter)
        .overlay {
            Image(systemName: systemName)
                .font(MusesTypography.system(size: ChromeActionMetrics.glyphSize, weight: .semibold))
                .foregroundStyle(foreground)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .contentShape(Circle())
        .modifier(CompactChromeSurface())
        .help(title)
        .accessibilityLabel(title)
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
