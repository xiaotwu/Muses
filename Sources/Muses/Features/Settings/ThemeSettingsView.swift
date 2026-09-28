import SwiftUI

struct ThemeSettingsView: View {
    @AppStorage(PrefKey.nowPlayingMode) private var modeRaw = NowPlayingMode.cover.rawValue
    @AppStorage(PrefKey.theme) private var themeRaw = AppTheme.system.rawValue

    var body: some View {
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
    }
}
