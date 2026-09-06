import SwiftUI

/// Language settings: system / English / Simplified Chinese.
struct LanguageSettingsView: View {
    @AppStorage(PrefKey.language) private var languageRaw: String = AppLanguage.system.rawValue

    private var language: AppLanguage {
        AppLanguage(rawValue: languageRaw) ?? .system
    }

    var body: some View {
        Section(tr("Language", "语言")) {
            Picker(tr("Language", "语言"), selection: Binding(
                get: { languageRaw },
                set: { languageRaw = $0 }
            )) {
                ForEach(AppLanguage.allCases, id: \.self) { lang in
                    Text(lang.displayName).tag(lang.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
        }
    }
}