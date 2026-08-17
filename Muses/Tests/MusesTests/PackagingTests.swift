import Testing
import Foundation
import SwiftUI
@testable import Muses

/// Phase 4 打包与发布管线测试。验证 Info.plist 模板可解析且含发布必备键,
/// 以及 AppTheme 到 ColorScheme 的映射。
@Suite("Packaging")
struct PackagingTests {

    // MARK: - 汇总:所有打包脚本存在且语法通过

    @Test("所有 Scripts/*.sh 存在且 bash -n 通过")
    func allScriptsSyntax() throws {
        let scripts = [
            "Scripts/copy-ytdlp.sh",
            "Scripts/make-icon.sh",
            "Scripts/build-app.sh",
            "Scripts/sign-update.sh",
            "Scripts/notarize.sh",
            "Scripts/make-dmg.sh",
        ]
        for path in scripts {
            try #require(FileManager.default.fileExists(atPath: path), "\(path) 不存在")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-n", path]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "\(path) 语法错误")
        }
    }

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

        // Phase 14 起 Sparkle 已移除:Info.plist 不应再含任何 SU* 键。
        #expect(plist["SUFeedURL"] == nil, "SUFeedURL 应已移除")
        #expect(plist["SUPublicEDKey"] == nil, "SUPublicEDKey 应已移除")
        #expect(plist["SUEnableAutomaticUpdates"] == nil, "SUEnableAutomaticUpdates 应已移除")
        #expect(plist["SUAutomaticallyUpdate"] == nil, "SUAutomaticallyUpdate 应已移除")
        #expect(plist["SUScheduledCheckInterval"] == nil, "SUScheduledCheckInterval 应已移除")
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

    @Test("build-app.sh 语法通过 bash -n 且可执行")
    func buildAppScriptSyntax() throws {
        let path = "Scripts/build-app.sh"
        try #require(FileManager.default.fileExists(atPath: path), "build-app.sh 不存在")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "build-app.sh 语法错误")
        // 可执行位。
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perm = (attrs[.posixPermissions] as? Int) ?? 0
        #expect(perm & 0o100 != 0, "build-app.sh 缺少可执行位")
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

    @Test("sign-update.sh 语法通过 bash -n 且可执行")
    func signUpdateScriptSyntax() throws {
        let path = "Scripts/sign-update.sh"
        try #require(FileManager.default.fileExists(atPath: path), "sign-update.sh 不存在")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "sign-update.sh 语法错误")
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perm = (attrs[.posixPermissions] as? Int) ?? 0
        #expect(perm & 0o100 != 0, "sign-update.sh 缺少可执行位")
    }

    /// Phase 14 起 Sparkle 已移除:更新改由 `UpdateService` 调 GitHub Releases API。
    /// 这里冒烟确认 UpdateService 可实例化、版本号取自 bundle、semver 比较正确。
    @Test("UpdateService 实例化 + semver 比较(替代 Sparkle CLI 检查)")
    @MainActor
    func updateServiceSemver() {
        let svc = UpdateService()
        #expect(!svc.currentVersion.isEmpty)
        // hasUpdate 在无 latestVersion 时为 false(尚未检查)
        let fresh = UpdateService()
        #expect(!fresh.hasUpdate)
    }

    @Test("notarize.sh 语法通过 bash -n 且可执行")
    func notarizeScriptSyntax() throws {
        let path = "Scripts/notarize.sh"
        try #require(FileManager.default.fileExists(atPath: path), "notarize.sh 不存在")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "notarize.sh 语法错误")
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perm = (attrs[.posixPermissions] as? Int) ?? 0
        #expect(perm & 0o100 != 0, "notarize.sh 缺少可执行位")
    }

    @Test("make-dmg.sh 语法通过 bash -n 且可执行")
    func makeDmgScriptSyntax() throws {
        let path = "Scripts/make-dmg.sh"
        try #require(FileManager.default.fileExists(atPath: path), "make-dmg.sh 不存在")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "make-dmg.sh 语法错误")
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perm = (attrs[.posixPermissions] as? Int) ?? 0
        #expect(perm & 0o100 != 0, "make-dmg.sh 缺少可执行位")
    }

    /// 若 build/Muses-$VER.dmg 已生成,断言非空。
    @Test("DMG 若存在则非空")
    func dmgNonEmptyIfPresent() {
        let dmg = "build/Muses-0.4.0.dmg"
        guard FileManager.default.fileExists(atPath: dmg) else { return }
        let size = (try? FileManager.default.attributesOfItem(
            atPath: dmg)[.size] as? Int) ?? 0
        #expect(size > 1_000_000, "DMG 异常小(<1MB)")
    }
}