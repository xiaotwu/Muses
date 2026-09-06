import SwiftUI

/// Theme settings: Now Playing mode (cover/vinyl) + app theme (dark/light/system).
struct ThemeSettingsView: View {
    @AppStorage(PrefKey.nowPlayingMode) private var modeRaw: String = NowPlayingMode.cover.rawValue
    @AppStorage(PrefKey.theme) private var themeRaw: String = AppTheme.dark.rawValue

    private var mode: NowPlayingMode {
        get { NowPlayingMode(rawValue: modeRaw) ?? .cover }
    }
    private var theme: AppTheme {
        get { AppTheme(rawValue: themeRaw) ?? .dark }
    }

    var body: some View {
        Section(tr("Now Playing Mode", "Now Playing 模式")) {
            Picker(tr("Display Mode", "展示模式"), selection: Binding(
                get: { modeRaw },
                set: { modeRaw = $0 }
            )) {
                Text(tr("Cover", "封面")).tag(NowPlayingMode.cover.rawValue)
                Text(tr("Vinyl", "黑胶")).tag(NowPlayingMode.vinyl.rawValue)
            }
            .pickerStyle(.radioGroup)
        }

        Section(tr("App Theme", "应用主题")) {
            Picker(tr("Theme", "主题"), selection: Binding(
                get: { themeRaw },
                set: { themeRaw = $0 }
            )) {
                Text(tr("Dark", "深色")).tag(AppTheme.dark.rawValue)
                Text(tr("Light", "浅色")).tag(AppTheme.light.rawValue)
                Text(tr("Match System", "跟随系统")).tag(AppTheme.system.rawValue)
            }
            .pickerStyle(.radioGroup)
        }
    }
}
