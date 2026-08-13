import SwiftUI

/// 主题设置: Now Playing 模式切换(封面/唱片) + 应用主题(阶段 2 仅 dark 生效)。
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
        Form {
            Section(tr("Now Playing Mode", "Now Playing 模式")) {
                Picker(tr("Display Mode", "展示模式"), selection: Binding(
                    get: { modeRaw },
                    set: { modeRaw = $0 }
                )) {
                    Text(tr("Large Cover", "巨大封面")).tag(NowPlayingMode.cover.rawValue)
                    Text(tr("Spinning Vinyl", "唱片旋转")).tag(NowPlayingMode.vinyl.rawValue)
                }
                .pickerStyle(.radioGroup)
                Text(tr("Choose the visual style of the Now Playing full-screen page.", "选择 Now Playing 全屏页面的视觉风格。"))
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
                Text(tr("Stage 2 supports only the Dark theme; Light / Match System will be implemented in stage 4.", "阶段 2 仅支持深色主题; 浅色/跟随系统将在阶段 4 实现。"))
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 480)
    }
}