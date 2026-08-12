import Testing
import Foundation
import SwiftUI
@testable import Muses

/// Phase 4 打包与发布管线测试。验证 Info.plist 模板可解析且含发布必备键,
/// 以及 AppTheme 到 ColorScheme 的映射。
@Suite("Packaging")
struct PackagingTests {

    // MARK: - Info.plist 模板

    /// Info.plist 是 Muses 模块资源(SPM `.copy("Resources")`)。
    @Test("Info.plist 模板可解析且含发布必备键")
    func infoPlistParsesAndHasRequiredKeys() throws {
        let url = try #require(MusesResources.infoPlistURL, "Info.plist 资源未找到")
        let data = try Data(contentsOf: url)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            "Info.plist 解析失败"
        )

        // 必备键。
        #expect(plist["CFBundleIdentifier"] as? String == "com.muses.app")
        #expect(plist["CFBundleExecutable"] as? String == "Muses")
        #expect(plist["CFBundlePackageType"] as? String == "APPL")
        #expect(plist["CFBundleShortVersionString"] as? String != nil)
        #expect(plist["CFBundleVersion"] as? String != nil)
        #expect(plist["LSMinimumSystemVersion"] as? String == "14.0")
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon")

        // Sparkle 键。
        #expect(plist["SUFeedURL"] as? String != nil)
        #expect(plist["SUEnableAutomaticUpdates"] as? Bool == true)
        #expect(plist["SUAutomaticallyUpdate"] as? Bool == false)
        // SUPublicEDKey 存在(发布前由 sign-update.sh 注入,初始可空)。
        #expect(plist["SUPublicEDKey"] != nil)
    }

    /// entitlements 模板可解析。
    @Test("Muses.entitlements 模板可解析")
    func entitlementsParses() throws {
        let url = try #require(MusesResources.entitlementsURL, "entitlements 资源未找到")
        let data = try Data(contentsOf: url)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            "entitlements 解析失败"
        )
        #expect(plist["com.apple.security.network.client"] as? Bool == true)
    }

    // MARK: - AppTheme 映射

    @Test("AppTheme.effectiveColorScheme 映射")
    func appThemeColorSchemeMapping() {
        #expect(AppTheme.dark.effectiveColorScheme == .dark)
        #expect(AppTheme.light.effectiveColorScheme == .light)
        #expect(AppTheme.system.effectiveColorScheme == nil)
    }
}