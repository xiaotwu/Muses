import SwiftUI

/// Settings-only action metrics. Menus, switches and selection rows keep their
/// native semantics instead of inheriting an action style from the entire Form.
extension View {
    func settingsAction(prominent: Bool = false) -> some View {
        buttonStyle(SettingsGlassActionStyle(prominent: prominent))
            .controlSize(.small)
            .frame(minHeight: 30)
    }
}

struct SettingsIconButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(MusesTypography.system(size: 13, weight: .semibold))
                .frame(width: 18, height: 18)
        }
        .settingsAction()
        .frame(minWidth: 30)
        .help(title)
        .accessibilityLabel(title)
    }
}

struct SettingsInfoButton: View {
    let title: String
    let message: String
    @State private var presented = false

    var body: some View {
        Button { presented.toggle() } label: {
            Image(systemName: "info.circle")
                .font(MusesTypography.system(size: 13))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.fullAreaPlain)
        .help(message)
        .accessibilityLabel(tr("About \(title)", "关于\(title)"))
        .popover(isPresented: $presented) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(MusesTypography.headline)
                Text(message).font(MusesTypography.callout).textSelection(.enabled)
            }
            .padding(16)
            .frame(width: 310, alignment: .leading)
        }
    }
}

struct SettingsStatus: View {
    let title: String
    var symbol = "checkmark.circle"
    var color: Color = BrandColors.textSecondary

    var body: some View {
        Label(title, systemImage: symbol)
            .font(MusesTypography.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsKeycaps: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(MusesTypography.caption.monospaced())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined(separator: " "))
    }
}

/// A help action is a sibling of the switch, never part of its label. This
/// prevents AppKit from adopting the help button's name as the switch label.
struct SettingsExplainedToggle: View {
    let title: String
    @Binding var isOn: Bool
    let information: String
    var enabled = true

    var body: some View {
        HStack(spacing: 6) {
            Text(title).accessibilityHidden(true)
            SettingsInfoButton(title: title, message: information)
            Spacer()
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .accessibilityLabel(title)
                .disabled(!enabled)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Keep the Button's native activation, focus and accessibility semantics while
/// using clear glass rather than the regular glass button style's opaque fill.
private struct SettingsGlassActionStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .foregroundStyle(configuration.role == .destructive ? Color.red : BrandColors.textPrimary)
            .background(BrandColors.accent.opacity(prominent ? 0.15 : (configuration.isPressed ? 0.08 : 0)), in: Capsule())
            .modifier(SettingsClearGlassSurface())
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.45)
    }
}
