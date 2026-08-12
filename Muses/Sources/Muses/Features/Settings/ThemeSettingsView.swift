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
            Section("Now Playing 模式") {
                Picker("展示模式", selection: Binding(
                    get: { modeRaw },
                    set: { modeRaw = $0 }
                )) {
                    Text("巨大封面").tag(NowPlayingMode.cover.rawValue)
                    Text("唱片旋转").tag(NowPlayingMode.vinyl.rawValue)
                }
                .pickerStyle(.radioGroup)
                Text("选择 Now Playing 全屏页面的视觉风格。")
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
            }

            Section("应用主题") {
                Picker("主题", selection: Binding(
                    get: { themeRaw },
                    set: { themeRaw = $0 }
                )) {
                    Text("深色").tag(AppTheme.dark.rawValue)
                    Text("浅色").tag(AppTheme.light.rawValue)
                    Text("跟随系统").tag(AppTheme.system.rawValue)
                }
                .pickerStyle(.radioGroup)
                Text("阶段 2 仅支持深色主题; 浅色/跟随系统将在阶段 4 实现。")
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 480)
    }
}