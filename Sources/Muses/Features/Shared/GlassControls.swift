import SwiftUI

/// Include transparent spacing inside a button's label in its interaction area.
struct FullAreaPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(.interaction, Rectangle())
    }
}

extension ButtonStyle where Self == FullAreaPlainButtonStyle {
    static var fullAreaPlain: Self { .init() }
}

private struct GroupedChromeActionsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var groupedChromeActions: Bool {
        get { self[GroupedChromeActionsKey.self] }
        set { self[GroupedChromeActionsKey.self] = newValue }
    }
}

/// Neutral P2 action chrome; grouped actions share their parent's glass.
struct CompactChromeSurface: ViewModifier {
    var selected = false
    var destructive = false
    @Environment(\.groupedChromeActions) private var grouped

    @ViewBuilder func body(content: Content) -> some View {
        if grouped {
            content.foregroundStyle(destructive ? Color.red : BrandColors.textPrimary)
                .background(selected ? BrandColors.accent.opacity(0.14) : .clear, in: Capsule())
        } else {
            content.foregroundStyle(destructive ? Color.red : (selected ? BrandColors.accent : BrandColors.textPrimary))
                .musesGlass(in: Capsule(), tint: selected ? BrandColors.accent.opacity(0.12) : nil, role: .compactControl)
        }
    }
}

/// T3 auxiliary transport: the dock supplies glass; glyphs remain lightweight.
struct MusesTransportButtonStyle: ButtonStyle {
    var selected = false
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 28, minHeight: 28)
            .background(BrandColors.accent.opacity(selected ? 0.14 : (hovered || configuration.isPressed ? 0.08 : 0)), in: Capsule())
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.45)
            .onHover { hovered = $0 }
    }
}

/// S2 single-selection item inside one neutral glass container.
struct MusesSegmentButtonStyle: ButtonStyle {
    var selected = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(BrandColors.accent.opacity(selected ? 0.15 : (configuration.isPressed ? 0.06 : 0)), in: Capsule())
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.45)
    }
}

/// T3 clear playback core, with a restrained champagne-gold tint and a luminous rim.
struct PlaybackCoreSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.foregroundStyle(BrandColors.playback)
            .musesGlass(in: Circle(), tint: BrandColors.accent.opacity(0.14), role: .artworkControl)
    }
}

extension ButtonStyle where Self == MusesTransportButtonStyle {
    static var musesTransport: Self { .init() }
    static func musesTransport(selected: Bool) -> Self { .init(selected: selected) }
}

extension ButtonStyle where Self == MusesSegmentButtonStyle {
    static func musesSegment(selected: Bool) -> Self { .init(selected: selected) }
}

struct MusesCompactButtonStyle: ButtonStyle {
    var padded = false
    var selected = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 28, minHeight: 28)
            .padding(.horizontal, padded ? 12 : 0)
            .padding(.vertical, padded ? 8 : 0)
            .modifier(CompactChromeSurface(selected: selected, destructive: configuration.role == .destructive))
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
    }
}

extension ButtonStyle where Self == MusesCompactButtonStyle {
    static var musesCompact: Self { .init() }
    static func musesCompact(selected: Bool) -> Self { .init(selected: selected) }
}

private struct MusesControls: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(.automatic)
    }
}

private struct MusesAction: ViewModifier {
    var prominent: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { content.buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(BrandColors.accent) }
            else { content.buttonStyle(.glass).buttonBorderShape(.capsule).tint(nil) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(BrandColors.accent) }
            else { content.buttonStyle(.bordered).buttonBorderShape(.capsule).tint(nil) }
        }
    }
}

extension View {
    func musesControls() -> some View { modifier(MusesControls()) }
    func musesAction(prominent: Bool = false) -> some View {
        modifier(MusesAction(prominent: prominent))
    }
}

/// A compact, keyboard-accessible choice group with a pale champagne-gold selection.
struct SettingsGlassChoice: View {
    struct Option: Identifiable {
        let id: String
        let title: String
        let symbol: String
        var isYouTube = false
    }
    let title: String
    @Binding var selection: String
    let options: [Option]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MusesGlassGroup(spacing: 8) { choices }
    }

    private var choices: some View {
        HStack(spacing: 8) {
            ForEach(options) { option in
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
                        selection = option.id
                    }
                } label: {
                    choiceLabel(option)
                }
                .buttonStyle(.musesSegment(selected: selection == option.id))
                .accessibilityAddTraits(selection == option.id ? .isSelected : [])
                .help(option.title)
            }
        }
        .padding(6)
        .modifier(SettingsClearGlassSurface())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    @ViewBuilder private func choiceLabel(_ option: Option) -> some View {
        let label = Label {
            Text(option.title)
        } icon: {
            if option.isYouTube { YouTubeMark(size: 14) }
            else { Image(systemName: option.symbol) }
        }
            .font(MusesTypography.body.weight(selection == option.id ? .semibold : .regular))
            .foregroundStyle(selection == option.id ? BrandColors.heading : BrandColors.heading.opacity(0.85))
            .frame(maxWidth: .infinity, minHeight: 32)
            .padding(.horizontal, 12)
            .contentShape(Capsule())
        label
    }
}

private struct SettingsSelection: ViewModifier {
    let selected: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), selected, !reduceTransparency, contrast != .increased {
            content.glassEffect(.regular.tint(BrandColors.selectionFill).interactive(!reduceMotion), in: Capsule())
                .overlay(alignment: .leading) { indicator }
        } else {
            content.background(selected ? BrandColors.selectionFill : .clear, in: Capsule())
                .overlay(alignment: .leading) { if selected { indicator } }
        }
    }

    private var indicator: some View {
        Capsule().fill(BrandColors.accent).frame(width: 3, height: 14)
            .padding(.leading, 3).allowsHitTesting(false).accessibilityHidden(true)
    }
}

extension View {
    func settingsSelection(_ selected: Bool) -> some View {
        modifier(SettingsSelection(selected: selected))
    }
}

/// Transparent glass for settings controls, with native accessibility fallbacks.
struct SettingsClearGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased {
            content.glassEffect(.clear.interactive(!reduceMotion), in: Capsule())
        } else {
            content.musesGlass(in: Capsule(), role: .compactControl)
        }
    }
}
