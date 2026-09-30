import AppKit
import SwiftUI

/// Approved T3C palette: indigo navigation, graphite playback, mist-gray surfaces.
enum MusesThemePalette {
    enum Role: CaseIterable {
        case accent, heading, selectionText, selectionFill, playback, onPlayback
        case page, surface, sidebar
    }

    static func hex(_ role: Role, dark: Bool, highContrast: Bool = false) -> String {
        switch role {
        case .accent: return dark ? "C0B0FF" : (highContrast ? "4D408D" : "6554C0")
        case .heading, .selectionText: return dark ? "C0B0FF" : "4D408D"
        case .selectionFill: return dark ? "353942" : "E6E7EB"
        case .playback: return dark ? "BDCADD" : "465469"
        case .onPlayback: return dark ? "151D29" : "FFFFFF"
        case .page: return highContrast ? (dark ? "000000" : "FFFFFF") : (dark ? "191D25" : "FAFBFD")
        case .surface: return dark ? "282D37" : "F1F2F5"
        case .sidebar: return dark ? "282B32" : "F1F2F5"
        }
    }

    static func resolved(_ role: Role, appearance: NSAppearance) -> NSColor {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let increased = [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                         .accessibilityHighContrastVibrantLight, .accessibilityHighContrastVibrantDark]
            .contains(appearance.name)
        let value = UInt32(hex(role, dark: dark, highContrast: increased), radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    static func color(_ role: Role) -> Color {
        Color(nsColor: NSColor(name: nil) { resolved(role, appearance: $0) })
    }
}
