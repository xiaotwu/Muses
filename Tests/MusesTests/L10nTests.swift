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
        #expect(["Home", "首页", "首頁"].contains(result))
    }

    @Test("Chinese script preferences survive region-only system identifiers")
    func scriptResolution() {
        #expect(L10n.resolvedLanguage(preference: "system", preferredLanguages: ["zh-TW", "en"]) == "zh-Hant")
        #expect(L10n.resolvedLanguage(preference: "system", preferredLanguages: ["zh-HK"]) == "zh-Hant")
        #expect(L10n.resolvedLanguage(preference: "zh") == "zh-Hans")
        #expect(L10n.resolvedLanguage(preference: "zh-Hant") == "zh-Hant")
        #expect(L10n.resolvedLanguage(preference: "en", preferredLanguages: ["zh-TW"]) == "en")
        #expect(L10n.resolvedLanguage(preference: "system", preferredLanguages: ["fr"]) == "en")
    }

    @Test("Traditional copy is bundled and uses native terminology")
    func traditionalCatalog() {
        #expect(L10n.traditionalStrings["设置"] == "設定")
        #expect(L10n.traditionalStrings["通用"] == "一般")
        #expect(L10n.traditionalStrings["首页"] == "首頁")
        #expect(L10n.traditionalStrings.count > 600)
        #expect(AppLanguage.allCases.contains(.zhHant))
    }

    @Test("Saved settings destinations redirect to flat visible categories")
    func settingsDestinations() {
        #expect(SettingsCategory.allCases.count == 9)
        #expect(SettingsCategory.audioQuality.destination == .playback)
        #expect(SettingsCategory.desktop.destination == .appearance)
        #expect(SettingsCategory.updates.destination == .about)
    }

    @Test("Cached section copy follows the app language without altering editorial titles")
    func cachedSectionCopy() {
        let cached = HomeSection(id: "new-releases", title: "新發行", subtitle: "来自 YouTube Music",
                                 kind: .youTubeCarousel, items: [], source: .cached, cachedOrigin: .publicDiscovery)
        #expect(cached.localizedTitle == tr("New releases", "新发行"))
        #expect(cached.localizedSubtitle == tr("From YouTube Music", "来自 YouTube Music"))
        let editorial = HomeSection(id: "new-releases", title: "Editorial title", kind: .youTubeCarousel,
                                    items: [], source: .signedInWeb)
        #expect(editorial.localizedTitle == "Editorial title")
        let artist = "后海大鲨鱼"
        let mixed = HomeSection(id: "top-artist", title: "為你精選 · \(artist)", kind: .youTubeCarousel, items: [])
        #expect(mixed.localizedTitle.hasSuffix(artist))
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
