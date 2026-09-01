import Testing
import SwiftUI
import AppKit
@testable import Muses

/// Theme tests: BrandColors dynamic NSColor resolves to different values under dark/light appearances,
/// and the AppTheme → ColorScheme mapping is correct.
@Suite("Theme")
struct ThemeTests {

    // MARK: - AppTheme mapping

    @Test("AppTheme.effectiveColorScheme 三分支")
    func appThemeColorScheme() {
        #expect(AppTheme.dark.effectiveColorScheme == .dark)
        #expect(AppTheme.light.effectiveColorScheme == .light)
        #expect(AppTheme.system.effectiveColorScheme == nil)
    }

    // MARK: - BrandColors dynamic resolution

    /// Resolves the sRGB components of an NSColor inside the drawing context of a given appearance.
    /// A dynamic NSColor(name:dynamicProvider:) resolves concrete components only inside an
    /// appearance drawing context; calling getRed directly fatals.
    private func components(of color: NSColor, appearance: NSAppearance) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var result: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        appearance.performAsCurrentDrawingAppearance {
            let resolved = color.usingColorSpace(.sRGB) ?? color
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
            result = (r, g, b)
        }
        return (result.0, result.1, result.2)
    }

    @Test("BrandColors.background 在 dark/light 下解析不同")
    func backgroundDynamic() {
        let dark = components(of: NSColor(BrandColors.background), appearance: NSAppearance(named: .darkAqua)!)
        let light = components(of: NSColor(BrandColors.background), appearance: NSAppearance(named: .aqua)!)
        // The dark background must be far darker than the light background
        #expect(dark.r < 0.2 && dark.g < 0.2 && dark.b < 0.2, "深色背景非暗色")
        #expect(light.r > 0.9 && light.g > 0.9, "浅色背景非近白")
        #expect(abs(dark.r - light.r) > 0.5, "background 未随外观变化")
    }

    @Test("BrandColors.textPrimary 在 dark/light 下反转")
    func textPrimaryDynamic() {
        let dark = components(of: NSColor(BrandColors.textPrimary), appearance: NSAppearance(named: .darkAqua)!)
        let light = components(of: NSColor(BrandColors.textPrimary), appearance: NSAppearance(named: .aqua)!)
        // Dark mode: bright text (>0.9); light mode: dark text (<0.2)
        #expect(dark.r > 0.9, "深色模式 textPrimary 应为亮色")
        #expect(light.r < 0.2, "浅色模式 textPrimary 应为暗色")
    }

    @Test("BrandColors.hairline 与 scrim token 存在且可解析")
    func hairlineAndScrimResolve() {
        let darkHair = components(of: NSColor(BrandColors.hairline), appearance: NSAppearance(named: .darkAqua)!)
        let lightHair = components(of: NSColor(BrandColors.hairline), appearance: NSAppearance(named: .aqua)!)
        // hairline is a low-alpha translucent overlay in both; white in dark, black in light
        #expect(darkHair.r > 0.9, "深色 hairline 应基于白色")
        #expect(lightHair.r < 0.1, "浅色 hairline 应基于黑色")

        let darkScrim = components(of: NSColor(BrandColors.scrim), appearance: NSAppearance(named: .darkAqua)!)
        let lightScrim = components(of: NSColor(BrandColors.scrim), appearance: NSAppearance(named: .aqua)!)
        #expect(darkScrim.r < 0.1, "scrim 应基于黑色")
        #expect(lightScrim.r < 0.1, "scrim 应基于黑色")
    }

    @Test("BrandColors 所有 token 可在两种外观下解析不崩溃")
    func allTokensResolveInBothAppearances() {
        let appearances: [NSAppearance] = [
            NSAppearance(named: .darkAqua)!,
            NSAppearance(named: .aqua)!,
        ]
        let tokens: [Color] = [
            BrandColors.background, BrandColors.surface, BrandColors.magenta,
            BrandColors.textPrimary,
            BrandColors.textSecondary, BrandColors.hairline, BrandColors.scrim,
        ]
        for appearance in appearances {
            for token in tokens {
                let ns = NSColor(token)
                var resolvedOK = false
                appearance.performAsCurrentDrawingAppearance {
                    if ns.usingColorSpace(.sRGB) != nil {
                        resolvedOK = true
                    }
                }
                #expect(resolvedOK, "token 解析失败")
            }
        }
    }
}
