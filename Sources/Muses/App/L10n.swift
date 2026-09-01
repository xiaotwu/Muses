import Foundation

/// i18n: pick a localized string from user preference, then system locale.
/// Call sites use `tr(en, zhHans)`; extra locales are optional.
enum L10n {
    /// True when the active locale is any Chinese variant.
    static var isChinese: Bool {
        let pref = UserDefaults.standard.string(forKey: PrefKey.language) ?? "system"
        if pref == "system" {
            return Locale.current.language.languageCode?.identifier.hasPrefix("zh") ?? false
        }
        return pref == "zh" || pref == "zh-Hans" || pref == "zh-Hant"
    }
}

/// Localized string. English is the default; Simplified Chinese is the current extra locale.
/// Optional Traditional Chinese and Japanese fall back to Simplified Chinese, then English.
func tr(_ en: String, _ zhHans: String, zhHant: String? = nil, ja: String? = nil) -> String {
    let pref = UserDefaults.standard.string(forKey: PrefKey.language) ?? "system"
    let code: String
    if pref == "system" {
        let id = Locale.current.language.languageCode?.identifier ?? "en"
        if id == "zh" {
            let script = Locale.current.language.script?.identifier
            code = (script == "Hant") ? "zh-Hant" : "zh-Hans"
        } else {
            code = id
        }
    } else {
        code = pref
    }
    switch code {
    case "zh", "zh-Hans": return zhHans
    case "zh-Hant": return zhHant ?? zhHans
    case "ja": return ja ?? en
    default: return en
    }
}