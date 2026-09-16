import SwiftUI

/// Use the platform's interaction, focus, menu, and accessibility implementations.
private struct MusesControls: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content.buttonStyle(.glass)
                .buttonBorderShape(.capsule)
            .transaction { if reduceMotion { $0.animation = nil } }
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private struct MusesAction: ViewModifier {
    var prominent: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            if prominent { content.buttonStyle(.glassProminent).buttonBorderShape(.capsule) }
            else { content.buttonStyle(.glass).buttonBorderShape(.capsule) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) }
            else { content.buttonStyle(.bordered) }
        }
    }
}

extension View {
    func musesControls() -> some View { modifier(MusesControls()) }
    func musesAction(prominent: Bool = false) -> some View {
        modifier(MusesAction(prominent: prominent))
    }
}

/// A compact, keyboard-accessible choice group with one moving glass selection.
struct SettingsGlassChoice: View {
    struct Option: Identifiable {
        let id: String
        let title: String
        let symbol: String
    }
    let title: String
    @Binding var selection: String
    let options: [Option]
    @Namespace private var glassSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

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
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option.id ? .isSelected : [])
                .help(option.title)
            }
        }
        .padding(6)
        .background(.primary.opacity(0.045), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    @ViewBuilder private func choiceLabel(_ option: Option) -> some View {
        let label = Label(option.title, systemImage: option.symbol)
            .font(.body.weight(selection == option.id ? .semibold : .regular))
            .foregroundStyle(BrandColors.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 42)
            .padding(.horizontal, 12)
            .contentShape(Capsule())
        if selection == option.id {
            if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased {
                label.glassEffect(.regular.interactive(!reduceMotion), in: Capsule())
                    .glassEffectID("selection", in: glassSelection)
            } else {
                label.background(BrandColors.accent.opacity(0.15), in: Capsule())
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.5), lineWidth: 1))
            }
        } else {
            label
        }
    }
}

private struct SettingsSelection: ViewModifier {
    let selected: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), selected, !reduceTransparency {
            content.glassEffect(.regular.interactive(!reduceMotion), in: Capsule())
        } else {
            content.background(selected ? BrandColors.accent.opacity(0.12) : .clear,
                               in: Capsule())
        }
    }
}

extension View {
    func settingsSelection(_ selected: Bool) -> some View {
        modifier(SettingsSelection(selected: selected))
    }
}
