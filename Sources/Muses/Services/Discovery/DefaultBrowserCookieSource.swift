import AppKit
import Foundation

/// Browser families whose profile layout is supported by the isolated helper.
/// This intentionally excludes arbitrary Chromium derivatives because their
/// cookies may live outside Chrome's profile directory.
enum WebHomeBrowserSource: String, CaseIterable, Codable, Sendable {
    case safari
    case chrome
    case firefox

    var displayName: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .firefox: "Firefox"
        }
    }
}

enum DefaultBrowserCookieSourceResolution: Equatable, Sendable {
    case supported(
        source: WebHomeBrowserSource,
        applicationName: String,
        bundleIdentifier: String
    )
    case unsupported(applicationName: String, bundleIdentifier: String)
    case unavailable
}

/// Resolves the macOS handler for an HTTPS YouTube Music URL. Resolution does
/// not launch the browser or read its profile.
@MainActor
enum DefaultBrowserCookieSourceDetector {
    static func resolve(
        workspace: NSWorkspace = .shared
    ) -> DefaultBrowserCookieSourceResolution {
        guard let targetURL = URL(string: "https://music.youtube.com/"),
              let applicationURL = workspace.urlForApplication(toOpen: targetURL) else {
            return .unavailable
        }

        let bundle = Bundle(url: applicationURL)
        let bundleIdentifier = bundle?.bundleIdentifier ?? ""
        let applicationName = (bundle?.object(
            forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? applicationURL.deletingPathExtension().lastPathComponent
        return resolution(
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName)
    }

    static func resolution(
        bundleIdentifier: String?,
        applicationName: String
    ) -> DefaultBrowserCookieSourceResolution {
        let identifier = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return .unavailable }

        let source: WebHomeBrowserSource? = switch identifier.lowercased() {
        case "com.apple.safari": .safari
        case "com.google.chrome": .chrome
        case "org.mozilla.firefox": .firefox
        default: nil
        }
        let resolvedName = name.isEmpty ? identifier : name
        if let source {
            return .supported(
                source: source,
                applicationName: resolvedName,
                bundleIdentifier: identifier)
        }
        return .unsupported(
            applicationName: resolvedName,
            bundleIdentifier: identifier)
    }
}
