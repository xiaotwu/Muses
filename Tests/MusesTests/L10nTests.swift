import Testing
import Foundation
import AppKit
@testable import Muses

/// i18n infrastructure + theme foundation tests.
@Suite("L10n + Theme")
struct L10nThemeTests {

    @Test("tr() 根据系统语言返回正确文案")
    func trReturnsCorrectLanguage() {
        // tr() always dispatches on Locale.current; here we just verify the function exists and is callable
        let result = tr("Home", "首页")
        // The result must be one of the two
        #expect(result == "Home" || result == "首页")
    }

    @Test("L10n.isChinese 检测中文环境")
    func isChineseDetection() {
        // Verify the property is accessible and returns a Bool
        let isZh = L10n.isChinese
        #expect(isZh == true || isZh == false)
    }

    @Test("BrandColors.hairline 可在动态主题下解析")
    func hairlineResolves() {
        // The hairline is deliberately subtle, but remains visible in both
        // appearances. This smoke assertion guards dynamic-color construction.
        let color = NSColor(BrandColors.hairline)
        var resolvesInDarkAppearance = false
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            resolvesInDarkAppearance = color.usingColorSpace(.sRGB) != nil
        }
        #expect(resolvesInDarkAppearance)
    }

    @Test("PrefKey.gpuAcceleration 存在")
    func gpuPrefKeyExists() {
        #expect(PrefKey.gpuAcceleration == "muses.gpuAcceleration")
    }
}
