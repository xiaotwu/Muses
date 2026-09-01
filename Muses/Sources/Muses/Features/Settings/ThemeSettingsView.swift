import SwiftUI

/// 主题设置: Now Playing 模式切换(封面/唱片) + 应用主题(深色/浅色/跟随系统)。
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
                Text(tr("Large Cover", "巨大封面")).tag(NowPlayingMode.cover.rawValue)
                Text(tr("Spinning Vinyl", "唱片旋转")).tag(NowPlayingMode.vinyl.rawValue)
            }
            .pickerStyle(.radioGroup)
            Text(tr("Large Cover is the default square artwork. Vinyl shows a circular cover that spins clockwise while playing, without a disc rim.", "默认巨大方块封面。唱片模式仅显示圆形封面,播放时匀速顺时针旋转,无黑胶边。"))
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
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
            Text(tr("Theme switches between near-black dark and near-white light appearances. Match System follows the OS appearance.", "主题在近黑深色与近白浅色外观间切换；跟随系统按系统外观自动适配。"))
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
        }
    }
}
