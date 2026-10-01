import AppKit
import Testing
@testable import Muses

struct MusesThemePaletteTests {
    @Test("G1 foreground pairs remain legible in both appearances")
    func contrast() {
        let pairs: [(MusesThemePalette.Role, MusesThemePalette.Role)] = [
            (.heading, .page), (.selectionText, .selectionFill),
            (.accent, .surface), (.onPlayback, .playback)
        ]
        for dark in [false, true] {
            for highContrast in [false, true] {
                for (foreground, background) in pairs {
                    let a = luminance(MusesThemePalette.hex(foreground, dark: dark, highContrast: highContrast))
                    let b = luminance(MusesThemePalette.hex(background, dark: dark, highContrast: highContrast))
                    #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5)
                }
            }
        }
    }

    @Test("Native appearance resolves champagne gold and graphite independently")
    func appearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua,
                     .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            let accent = MusesThemePalette.resolved(.accent, appearance: appearance)
            let playback = MusesThemePalette.resolved(.playback, appearance: appearance)
            #expect(accent != playback)
            #expect(accent.alphaComponent == 1)
            #expect(playback.alphaComponent == 1)
        }
    }

    private func luminance(_ hex: String) -> Double {
        let value = UInt32(hex, radix: 16)!
        let components = [Double((value >> 16) & 255), Double((value >> 8) & 255), Double(value & 255)]
            .map { component in
                let s = component / 255
                return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
        return components[0] * 0.2126 + components[1] * 0.7152 + components[2] * 0.0722
    }
}
