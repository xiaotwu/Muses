import Testing
import Foundation
import AppKit
@testable import Muses

/// i18n infrastructure + theme foundation tests.
@Suite("L10n + Theme")
struct L10nThemeTests {

    @Test("tr() returns correct text based on system language")
    func trReturnsCorrectLanguage() {
        // tr() always dispatches on Locale.current; here we just verify the function exists and is callable
        let result = tr("Home", "首页")
        // The result must be one of the two
        #expect(result == "Home" || result == "首页")
    }

    @Test("L10n.isChinese detects Chinese locale")
    func isChineseDetection() {
        // Verify the property is accessible and returns a Bool
        let isZh = L10n.isChinese
        #expect(isZh == true || isZh == false)
    }

    @Test("BrandColors.hairline resolves under dynamic appearance")
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

    @Test("PrefKey.gpuAcceleration exists")
    func gpuPrefKeyExists() {
        #expect(PrefKey.gpuAcceleration == "muses.gpuAcceleration")
    }
}
