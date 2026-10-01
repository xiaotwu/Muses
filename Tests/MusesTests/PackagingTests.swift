import Testing
import Foundation
import SwiftUI
@testable import Muses

/// Packaging and release pipeline tests. Verifies the Info.plist template parses and contains the keys required for release,
/// plus the AppTheme → ColorScheme mapping.
@Suite("Packaging")
struct PackagingTests {
    /// Resolve repository assets from this source file instead of relying on
    /// SwiftPM's process working directory, which differs between runners.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MusesTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository
    }

    private func repositoryPath(_ relativePath: String) -> String {
        repositoryRoot.appending(path: relativePath).path
    }

    // MARK: - Summary: all packaging scripts exist and pass syntax checks

    @Test("all Scripts/*.sh exist and pass bash -n")
    func allScriptsSyntax() throws {
        let scripts = [
            "Scripts/copy-ytdlp.sh",
            "Scripts/make-icon.sh",
            "Scripts/sync-app-icon.sh",
            "Scripts/build-app.sh",
            "Scripts/sign-update.sh",
            "Scripts/notarize.sh",
            "Scripts/make-dmg.sh",
        ]
        for relativePath in scripts {
            let path = repositoryPath(relativePath)
            try #require(FileManager.default.fileExists(atPath: path), "\(relativePath) does not exist")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-n", path]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "\(path) failed bash -n")
        }
    }

    // MARK: - Info.plist template

    @Test("modern icon preserves canonical artwork with an opaque white background")
    func modernIconAppearance() throws {
        let document = try Data(contentsOf: repositoryRoot.appending(path: "assets/Muses.icon/icon.json"))
        let icon = try #require(JSONSerialization.jsonObject(with: document) as? [String: Any])
        let fill = try #require(icon["fill"] as? [String: String])
        #expect(fill["solid"] == "extended-srgb:1.00000,1.00000,1.00000,1.00000")
        let groups = try #require(icon["groups"] as? [[String: Any]])
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group["specular"] as? Bool == false)
        #expect((group["shadow"] as? [String: Any])?["kind"] as? String == "none")
        #expect((group["translucency"] as? [String: Any])?["enabled"] as? Bool == false)
        let layers = try #require(group["layers"] as? [[String: Any]])
        #expect(layers.count == 1)
        #expect(layers.first?["glass"] as? Bool == false)
        let canonical = try Data(contentsOf: repositoryRoot.appending(path: "assets/icon.png"))
        let layer = try Data(contentsOf: repositoryRoot.appending(path: "assets/Muses.icon/Assets/icon.png"))
        #expect(layer == canonical)
    }

    /// Info.plist is a Muses module resource (SPM `.copy("Resources")`).
    @Test("Info.plist template parses and contains release-required keys")
    func infoPlistParsesAndHasRequiredKeys() throws {
        let url = try #require(MusesResources.infoPlistURL, "Info.plist resource not found")
        let data = try Data(contentsOf: url)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            "Failed to parse Info.plist"
        )

        // Required keys.
        #expect(plist["CFBundleIdentifier"] as? String == "com.muses.app")
        #expect(plist["CFBundleExecutable"] as? String == "Muses")
        #expect(plist["CFBundlePackageType"] as? String == "APPL")
        #expect(plist["CFBundleShortVersionString"] as? String != nil)
        #expect(plist["CFBundleVersion"] as? String != nil)
        #expect(plist["LSMinimumSystemVersion"] as? String == "14.0")
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
        #expect(plist["MusesWebHomeEnabled"] as? Bool == true)

        // Public keys and feed URLs are injected by release packaging.
        #expect(plist["SUFeedURL"] as? String == "")
        #expect(plist["SUPublicEDKey"] as? String == "")
        #expect(plist["SURequireSignedFeed"] as? Bool == true)
        #expect(plist["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(plist["SUEnableAutomaticChecks"] as? Bool == false)
        #expect(plist["SUAutomaticallyUpdate"] as? Bool == false)
        #expect(plist["SUScheduledCheckInterval"] as? Int == 86_400)
    }

    /// The entitlements template parses.
    @Test("Muses.entitlements template parses")
    func entitlementsParses() throws {
        let url = try #require(MusesResources.entitlementsURL, "entitlements resource not found")
        let data = try Data(contentsOf: url)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            "Failed to parse entitlements"
        )
        #expect(plist["com.apple.security.network.client"] as? Bool == true)
    }

    // MARK: - AppTheme mapping

    @Test("AppTheme.effectiveColorScheme mapping")
    func appThemeColorSchemeMapping() {
        #expect(AppTheme.dark.effectiveColorScheme == .dark)
        #expect(AppTheme.light.effectiveColorScheme == .light)
        #expect(AppTheme.system.effectiveColorScheme == nil)
    }

    // MARK: - Shell script syntax

    /// Every packaging script must pass the `bash -n` syntax check.
    @Test("make-icon.sh passes bash -n")
    func makeIconScriptSyntax() throws {
        let path = repositoryPath("Scripts/make-icon.sh")
        try #require(FileManager.default.fileExists(atPath: path),
                     "make-icon.sh does not exist")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "make-icon.sh failed bash -n")
    }

    @Test("build-app.sh passes bash -n and is executable")
    func buildAppScriptSyntax() throws {
        let path = repositoryPath("Scripts/build-app.sh")
        try #require(FileManager.default.fileExists(atPath: path), "build-app.sh does not exist")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "build-app.sh failed bash -n")
        // Executable bit.
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perm = (attrs[.posixPermissions] as? Int) ?? 0
        #expect(perm & 0o100 != 0, "build-app.sh is missing the executable bit")
    }

    @Test("Web Home helper is built, embedded at a fixed path, and signed before the app")
    func helperPackagingContract() throws {
        let package = try String(
            contentsOfFile: repositoryPath("Package.swift"), encoding: .utf8)
        let script = try String(
            contentsOfFile: repositoryPath("Scripts/build-app.sh"), encoding: .utf8)

        #expect(package.contains("MusesWebHomeProtocol"))
        #expect(package.contains("MusesWebHomeCore"))
        #expect(package.contains("MusesWebHomeHelper"))
        #expect(script.contains("$CONTENTS/Helpers"))
        #expect(script.contains("$RELEASE_DIR/MusesWebHomeHelper"))
        #expect(script.contains("swift build -c release --show-bin-path"))
        #expect(script.contains("$CONTENTS/Resources/Muses_Muses.bundle"))
        #expect(script.contains("codesign --verify --strict \"$CONTENTS/Helpers/MusesWebHomeHelper\""))
        let helperSign = try #require(script.range(
            of: "--sign \"$IDENTITY\" \"$CONTENTS/Helpers/MusesWebHomeHelper\""))
        let appSign = try #require(script.range(
            of: "--entitlements \"$ENTITLEMENTS\""))
        #expect(helperSign.lowerBound < appSign.lowerBound)
    }

    /// If AppIcon.icns was generated (the script has run), assert it is non-empty.
    @Test("AppIcon.icns is non-empty when present")
    func appIconNonEmptyIfPresent() {
        let path = repositoryPath("Sources/Muses/Resources/AppIcon.icns")
        guard FileManager.default.fileExists(atPath: path)
        else {
            // Skip this assertion in CI or when make-icon.sh has not been run.
            return
        }
        let size = (try? FileManager.default.attributesOfItem(
            atPath: path)[.size] as? Int) ?? 0
        #expect(size > 0, "AppIcon.icns is empty")
    }

    @Test("Application icon resources preserve the original white background")
    func iconWhiteBackground() throws {
        let canonical = try Data(contentsOf: URL(fileURLWithPath: repositoryPath("assets/icon.png")))
        for copy in ["Sources/Muses/Resources/icon.png", "docs/assets/icon.png"] {
            #expect(try Data(contentsOf: URL(fileURLWithPath: repositoryPath(copy))) == canonical)
        }
        for path in ["assets/icon.png", "Sources/Muses/Resources/AppIcon.icns"] {
            let absolute = repositoryPath(path)
            guard FileManager.default.fileExists(atPath: absolute) else { continue }
            let image = try #require(NSImage(contentsOfFile: absolute))
            let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let outside = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 20,
                                                      y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            #expect(outside.alphaComponent > 0.95)
            #expect(outside.redComponent > 0.95 && outside.greenComponent > 0.95
                && outside.blueComponent > 0.95, "The original white background is missing from \(path)")
            let inside = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2,
                                                     y: bitmap.pixelsHigh / 2))
            #expect(inside.alphaComponent > 0.95)
        }
    }

    @Test("sign-update.sh passes bash -n and is executable")
    func signUpdateScriptSyntax() throws {
        let path = repositoryPath("Scripts/sign-update.sh")
        try #require(FileManager.default.fileExists(atPath: path), "sign-update.sh does not exist")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "sign-update.sh failed bash -n")
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perm = (attrs[.posixPermissions] as? Int) ?? 0
        #expect(perm & 0o100 != 0, "sign-update.sh is missing the executable bit")
    }

    @Test("Sparkle packaging signs helpers before the framework and app")
    func sparklePackaging() throws {
        let script = try String(contentsOfFile: repositoryPath("Scripts/build-app.sh"), encoding: .utf8)
        #expect(script.contains("$CONTENTS/Frameworks/Sparkle.framework"))
        #expect(script.contains("$SPARKLE/XPCServices/Downloader.xpc"))
        #expect(script.contains("$SPARKLE/XPCServices/Installer.xpc"))
        #expect(script.contains("$SPARKLE/Autoupdate"))
        #expect(script.contains("$SPARKLE/Updater.app"))
        #expect(script.contains("configure-updates.py"))
        let helper = try #require(script.range(of: "for component in"))
        let application = try #require(script.range(of: "codesign --deep --force"))
        #expect(helper.lowerBound < application.lowerBound)
    }

    @Test("notarize.sh passes bash -n and is executable")
    func notarizeScriptSyntax() throws {
        let path = repositoryPath("Scripts/notarize.sh")
        try #require(FileManager.default.fileExists(atPath: path), "notarize.sh does not exist")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "notarize.sh failed bash -n")
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perm = (attrs[.posixPermissions] as? Int) ?? 0
        #expect(perm & 0o100 != 0, "notarize.sh is missing the executable bit")
    }

    @Test("make-dmg.sh passes bash -n and is executable")
    func makeDmgScriptSyntax() throws {
        let path = repositoryPath("Scripts/make-dmg.sh")
        try #require(FileManager.default.fileExists(atPath: path), "make-dmg.sh does not exist")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "make-dmg.sh failed bash -n")
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perm = (attrs[.posixPermissions] as? Int) ?? 0
        #expect(perm & 0o100 != 0, "make-dmg.sh is missing the executable bit")
    }

    /// If build/Muses-$VER.dmg was generated, assert it is non-empty.
    @Test("DMG is non-empty when present")
    func dmgNonEmptyIfPresent() {
        let dmg = repositoryPath("build/Muses-0.4.0.dmg")
        guard FileManager.default.fileExists(atPath: dmg) else { return }
        let size = (try? FileManager.default.attributesOfItem(
            atPath: dmg)[.size] as? Int) ?? 0
        #expect(size > 1_000_000, "DMG is suspiciously small (<1MB)")
    }
}
