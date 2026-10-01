import SwiftUI
import AppKit

struct ThemeSettingsView: View {
    @AppStorage(PrefKey.nowPlayingMode) private var modeRaw = NowPlayingMode.cover.rawValue
    @AppStorage(PrefKey.theme) private var themeRaw = AppTheme.system.rawValue
    @State private var typography = TypographyPreferences.shared
    @State private var showFonts = false

    var body: some View {
        @Bindable var typography = typography
        Section {
            LabeledContent(tr("Theme", "主题")) {
                SettingsGlassChoice(title: tr("Theme", "主题"), selection: $themeRaw, options: [
                    .init(id: AppTheme.system.rawValue, title: tr("System", "系统"), symbol: "desktopcomputer"),
                    .init(id: AppTheme.light.rawValue, title: tr("Light", "浅色"), symbol: "sun.max"),
                    .init(id: AppTheme.dark.rawValue, title: tr("Dark", "深色"), symbol: "moon")
                ])
            }
            LabeledContent(tr("Now Playing", "正在播放")) {
                SettingsGlassChoice(title: tr("Now Playing", "正在播放"), selection: $modeRaw, options: [
                    .init(id: NowPlayingMode.cover.rawValue, title: tr("Cover", "封面"), symbol: "square"),
                    .init(id: NowPlayingMode.vinyl.rawValue, title: tr("Vinyl", "黑胶"), symbol: "opticaldisc")
                ])
            }
        } header: { Text(tr("Theme & artwork", "主题与封面")) }
        Section {
            LabeledContent(tr("Text size", "字号")) {
                SettingsGlassChoice(title: tr("Text size", "字号"), selection: Binding(
                    get: { typography.size.rawValue },
                    set: { if let size = InterfaceTextSize(rawValue: $0) { typography.size = size } }
                ), options: InterfaceTextSize.allCases.map {
                    .init(id: $0.rawValue, title: $0.label, symbol: "textformat.size")
                })
            }
            LabeledContent(tr("Font", "字体")) {
                Button { showFonts = true } label: {
                    Label(typography.family.isEmpty
                          ? tr("Muses default", "Muses 默认字体") : typography.family,
                          systemImage: "textformat")
                        .lineLimit(1)
                }
                .settingsAction()
                .popover(isPresented: $showFonts) {
                    SettingsFontPicker(typography: typography)
                }
            }
            Text(tr("Music title · Spring Prelude", "音乐标题 · 春日序曲"))
                .font(MusesTypography.song(size: 15))
                .foregroundStyle(BrandColors.textSecondary)
                .accessibilityLabel(tr("Font preview", "字体预览"))
        } header: { Text(tr("Text", "文字")) }
    }
}

/// Load the complete system font list only while its native popover is visible.
private struct SettingsFontPicker: View {
    @Bindable var typography: TypographyPreferences
    @State private var families: [String] = []
    @State private var query = ""
    @FocusState private var searching: Bool

    private var filtered: [String] {
        families.filter { query.isEmpty || $0.localizedStandardContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Font", "字体")).font(MusesTypography.headline)
            TextField(tr("Search system fonts", "搜索系统字体"), text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searching)
            ScrollView {
                LazyVStack(spacing: 2) {
                    fontRow("", title: tr("Muses default", "Muses 默认字体"))
                    ForEach(filtered, id: \.self) { family in fontRow(family, title: family) }
                }
            }
            Text(tr("Aa · Music and poetry", "Aa · 音乐与诗篇"))
                .font(MusesTypography.song(size: 15))
                .accessibilityLabel(tr("Font preview", "字体预览"))
        }
        .padding(16)
        .frame(width: 360, height: 360)
        .task {
            families = NSFontManager.shared.availableFontFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            searching = true
        }
    }

    private func fontRow(_ family: String, title: String) -> some View {
        Button { typography.family = family } label: {
            HStack {
                Text(title)
                Spacer()
                if typography.family == family { Image(systemName: "checkmark") }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 30)
            .settingsSelection(typography.family == family)
            .contentShape(Rectangle())
        }
        .buttonStyle(.fullAreaPlain)
        .accessibilityAddTraits(typography.family == family ? .isSelected : [])
    }
}
