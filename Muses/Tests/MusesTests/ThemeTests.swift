import Testing
import SwiftUI
import AppKit
@testable import Muses

/// Phase 4 主题测试:BrandColors 动态 NSColor 在 dark/light 外观下解析为不同值,
/// 以及 AppTheme → ColorScheme 映射正确。
@Suite("Theme")
struct ThemeTests {

    // MARK: - AppTheme 映射

    @Test("AppTheme.effectiveColorScheme 三分支")
    func appThemeColorScheme() {
        #expect(AppTheme.dark.effectiveColorScheme == .dark)
        #expect(AppTheme.light.effectiveColorScheme == .light)
        #expect(AppTheme.system.effectiveColorScheme == nil)
    }

    // MARK: - BrandColors 动态解析

    /// 在指定外观的 drawing context 内解析 NSColor 的 sRGB 分量。
    /// 动态 NSColor(name:dynamicProvider:) 只在 appearance drawing context
    /// 中才解析出具体分量;直接 getRed 会 fatal。
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
        // 深色背景应远暗于浅色背景
        #expect(dark.r < 0.2 && dark.g < 0.2 && dark.b < 0.2, "深色背景非暗色")
        #expect(light.r > 0.9 && light.g > 0.9, "浅色背景非近白")
        #expect(abs(dark.r - light.r) > 0.5, "background 未随外观变化")
    }

    @Test("BrandColors.textPrimary 在 dark/light 下反转")
    func textPrimaryDynamic() {
        let dark = components(of: NSColor(BrandColors.textPrimary), appearance: NSAppearance(named: .darkAqua)!)
        let light = components(of: NSColor(BrandColors.textPrimary), appearance: NSAppearance(named: .aqua)!)
        // 深色模式:亮字(>0.9);浅色模式:暗字(<0.2)
        #expect(dark.r > 0.9, "深色模式 textPrimary 应为亮色")
        #expect(light.r < 0.2, "浅色模式 textPrimary 应为暗色")
    }

    @Test("BrandColors.hairline 与 scrim token 存在且可解析")
    func hairlineAndScrimResolve() {
        let darkHair = components(of: NSColor(BrandColors.hairline), appearance: NSAppearance(named: .darkAqua)!)
        let lightHair = components(of: NSColor(BrandColors.hairline), appearance: NSAppearance(named: .aqua)!)
        // hairline 两者都是低 alpha 半透明;深色用白,浅色用黑
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
            BrandColors.cyan, BrandColors.green, BrandColors.textPrimary,
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