import SwiftUI

/// 语言设置:跟随系统 / English / 中文。
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
            Text(tr("Changes take effect immediately.",
                    "更改后立即生效。"))
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
        }
    }
}