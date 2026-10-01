import SwiftUI
import AppKit

struct ThemeSettingsView: View {
    @AppStorage(PrefKey.nowPlayingMode) private var modeRaw = NowPlayingMode.cover.rawValue
    @AppStorage(PrefKey.theme) private var themeRaw = AppTheme.system.rawValue

    @State private var typography = TypographyPreferences.shared
    @State private var families: [String] = []
    @State private var fontQuery = ""

    var body: some View {
        @Bindable var typography = typography
        Section {
            Picker(tr("Theme", "主题"), selection: $themeRaw) {
                Text(tr("Match System", "跟随系统")).tag(AppTheme.system.rawValue)
                Text(tr("Light", "浅色")).tag(AppTheme.light.rawValue)
                Text(tr("Dark", "深色")).tag(AppTheme.dark.rawValue)
            }
            .pickerStyle(.menu)
            Picker(tr("Now Playing artwork", "正在播放封面"), selection: $modeRaw) {
                Text(tr("Cover", "封面")).tag(NowPlayingMode.cover.rawValue)
                Text(tr("Vinyl", "黑胶")).tag(NowPlayingMode.vinyl.rawValue)
            }
            .pickerStyle(.menu)
        } header: { Text(tr("Appearance", "外观")) }
        Section {
            ForEach(InterfaceTextSize.allCases) { size in
                Button { typography.size = size } label: {
                    HStack {
                        Text(size.label)
                        Spacer()
                        if typography.size == size { Image(systemName: "checkmark") }
                    }.frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.fullAreaPlain)
                .accessibilityAddTraits(typography.size == size ? .isSelected : [])
            }
        } header: { Text(tr("Text Size", "字体大小")) }
        Section {
            TextField(tr("Filter system fonts", "筛选系统字体"), text: $fontQuery)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 2) {
                    fontRow("", title: tr("Default Muses Typography", "Muses 默认字体"))
                    ForEach(families.filter { fontQuery.isEmpty || $0.localizedStandardContains(fontQuery) }, id: \.self) { family in
                        fontRow(family, title: family)
                    }
                }
            }.frame(height: 220)
            Text(tr("Applies immediately throughout Muses. Unavailable fonts use the default typography.",
                    "立即应用于 Muses。字体不可用时使用默认字体。"))
                .font(MusesTypography.caption).foregroundStyle(.secondary)
        } header: { Text(tr("Font", "字体")) }
        .task { families = NSFontManager.shared.availableFontFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    }
    private func fontRow(_ family: String, title: String) -> some View {
        Button { typography.family = family } label: {
            HStack {
                Text(title)
                Spacer()
                if typography.family == family { Image(systemName: "checkmark") }
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .padding(.horizontal, 8)
            .settingsSelection(typography.family == family)
        }
        .buttonStyle(.fullAreaPlain)
        .accessibilityAddTraits(typography.family == family ? .isSelected : [])
    }
}
