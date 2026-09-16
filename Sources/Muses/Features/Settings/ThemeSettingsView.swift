import SwiftUI

/// Theme settings: Now Playing mode (cover/vinyl) + app theme (dark/light/system).
struct ThemeSettingsView: View {
    @AppStorage(PrefKey.nowPlayingMode) private var modeRaw: String = NowPlayingMode.cover.rawValue
    @AppStorage(PrefKey.theme) private var themeRaw: String = AppTheme.system.rawValue

    var body: some View {
        Section {
            SettingsGlassChoice(title: tr("Display Mode", "展示模式"), selection: $modeRaw, options: [
                .init(id: NowPlayingMode.cover.rawValue, title: tr("Cover", "封面"), symbol: "square"),
                .init(id: NowPlayingMode.vinyl.rawValue, title: tr("Vinyl", "黑胶"), symbol: "opticaldisc")
            ])
        } header: { Text(tr("Now Playing Mode", "Now Playing 模式")).font(.headline.weight(.semibold)) }
        Section {
            SettingsGlassChoice(title: tr("Theme", "主题"), selection: $themeRaw, options: [
                .init(id: AppTheme.system.rawValue, title: tr("Match System", "跟随系统"), symbol: "desktopcomputer"),
                .init(id: AppTheme.light.rawValue, title: tr("Light", "浅色"), symbol: "sun.max"),
                .init(id: AppTheme.dark.rawValue, title: tr("Dark", "深色"), symbol: "moon")
            ])
        } header: { Text(tr("App Theme", "应用主题")).font(.headline.weight(.semibold)) }
    }
}
