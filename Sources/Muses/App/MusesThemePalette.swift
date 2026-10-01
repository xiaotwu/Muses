import AppKit
import SwiftUI

/// Approved G1 palette: champagne-gold accents, graphite playback, warm-white surfaces.
enum MusesThemePalette {
    enum Role: CaseIterable {
        case accent, heading, selectionText, selectionFill, playback, onPlayback
        case page, surface, sidebar
    }

    static func hex(_ role: Role, dark: Bool, highContrast: Bool = false) -> String {
        switch role {
        // Deepen the light accent for small glyphs and text on warm glass surfaces.
        case .accent: return dark ? "DFC28B" : (highContrast ? "6D522C" : "86632E")
        case .heading, .selectionText: return dark ? "F5E3BF" : "6D522C"
        case .selectionFill: return dark ? "4F4635" : "EEE4D1"
        case .playback: return dark ? "C7CDD4" : "44505C"
        case .onPlayback: return dark ? "182029" : "FFFFFF"
        case .page: return highContrast ? (dark ? "000000" : "FFFFFF") : (dark ? "211F1B" : "FCFAF6")
        case .surface: return dark ? "302B23" : "F0ECE4"
        case .sidebar: return dark ? "2C2821" : "F2EEE6"
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
