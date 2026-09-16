import SwiftUI

/// Language names remain in their own language so switching back is discoverable.
struct LanguageSettingsView: View {
    @AppStorage(PrefKey.language) private var languageRaw: String = AppLanguage.system.rawValue

    private var language: AppLanguage {
        AppLanguage(rawValue: languageRaw) ?? .system
    }

    var body: some View {
        Section {
            Picker(tr("Language", "语言"), selection: Binding(
                get: { languageRaw },
                set: { languageRaw = $0 }
            )) {
                ForEach(AppLanguage.allCases, id: \.self) { lang in
                    Text(lang.displayName).tag(lang.rawValue)
                }
            }
            .pickerStyle(.menu)
        } header: { Text(tr("Language", "语言")).font(.headline.weight(.semibold)) }
    }
}
