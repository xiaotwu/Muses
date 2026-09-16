import Foundation
import Observation

/// Observation invalidates translated views without destroying their navigation,
/// sheets, focus, or async tasks. The lock also supports error strings off-main.
@Observable
final class LanguagePreferences: @unchecked Sendable {
    static let shared = LanguagePreferences()
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var storedValue: String

    private init() {
        storedValue = UserDefaults.standard.string(forKey: PrefKey.language) ?? "system"
    }

    var rawValue: String {
        access(keyPath: \.rawValue)
        return lock.withLock { storedValue }
    }

    func update(_ value: String) {
        guard rawValue != value else { return }
        withMutation(keyPath: \.rawValue) {
            lock.withLock { storedValue = value }
        }
    }
}

/// Shared locale resolution preserves the original `zh` preference and handles
/// region-only system identifiers such as zh-TW and zh-HK.
enum L10n {
    static func resolvedLanguage(preference: String, preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        let identifier = preference == "system" ? (preferredLanguages.first ?? "en") : preference
        let locale = Locale(identifier: identifier)
        guard locale.language.languageCode?.identifier == "zh" else { return "en" }
        if locale.language.script?.identifier == "Hant"
            || ["TW", "HK", "MO"].contains(locale.region?.identifier ?? "") {
            return "zh-Hant"
        }
        return "zh-Hans"
    }

    static var languageCode: String {
        // Register view observation while keeping direct preference writes and
        // application commands consistent before SwiftUI's onChange runs.
        let _ = LanguagePreferences.shared.rawValue
        return resolvedLanguage(preference: UserDefaults.standard.string(forKey: PrefKey.language) ?? "system")
    }

    static var isChinese: Bool { languageCode.hasPrefix("zh") }

    /// Loaded once, including before the first scene is composed. Dynamic copy
    /// supplies an explicit Traditional Chinese literal to preserve user text.
    static let traditionalStrings: [String: String] = {
        let urls = [
            Bundle.module.url(forResource: "zh-Hant", withExtension: "json", subdirectory: "Resources/Localization"),
            Bundle.main.url(forResource: "zh-Hant", withExtension: "json", subdirectory: "Localization")
        ]
        for case let url? in urls {
            if let data = try? Data(contentsOf: url),
               let strings = try? JSONDecoder().decode([String: String].self, from: data) { return strings }
        }
        return [:]
    }()
}

/// Existing call sites remain source-compatible. UI language and lyric language
/// are separate preferences; catalog names and lyrics are never transliterated here.
func tr(_ en: String, _ zhHans: String, zhHant: String? = nil, ja: String? = nil) -> String {
    switch L10n.languageCode {
    case "zh-Hans": return zhHans
    case "zh-Hant": return zhHant ?? L10n.traditionalStrings[zhHans] ?? zhHans
    default: return en
    }
}
