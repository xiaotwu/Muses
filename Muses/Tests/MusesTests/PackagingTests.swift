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

    // MARK: - Shell 脚本语法

    /// 所有打包脚本应通过 `bash -n` 语法检查。
    @Test("make-icon.sh 语法通过 bash -n")
    func makeIconScriptSyntax() throws {
        try #require(FileManager.default.fileExists(atPath: "Scripts/make-icon.sh"),
                     "make-icon.sh 不存在")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", "Scripts/make-icon.sh"]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "make-icon.sh 语法错误")
    }

    /// 若 AppIcon.icns 已生成(脚本运行过),断言非空。
    @Test("AppIcon.icns 若存在则非空")
    func appIconNonEmptyIfPresent() {
        guard FileManager.default.fileExists(
            atPath: "Muses/Sources/Muses/Resources/AppIcon.icns")
        else {
            // CI/未跑 make-icon.sh 时跳过本断言。
            return
        }
        let size = (try? FileManager.default.attributesOfItem(
            atPath: "Muses/Sources/Muses/Resources/AppIcon.icns")[.size] as? Int) ?? 0
        #expect(size > 0, "AppIcon.icns 为空")
    }
}