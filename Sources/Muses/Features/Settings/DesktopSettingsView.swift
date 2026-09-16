import SwiftUI

/// Desktop integration settings: global hotkeys / menu bar tray / mini player / desktop lyrics.
/// Each toggle's `.onChange` posts `.musesDesktopFlagsChanged`, which `MusesApp` uses to re-sync services.
/// Everything defaults to off (privacy-first / non-intrusive); enabling takes effect immediately and disabling releases the system resources.
struct DesktopSettingsView: View {
    @Environment(RuntimeCapabilities.self) private var capabilities
    @AppStorage(PrefKey.ffGlobalHotkeys) private var globalHotkeys = false
    @AppStorage(PrefKey.ffTray)            private var tray = true
    @AppStorage(PrefKey.ffMiniPlayer)     private var miniPlayer = false
    @AppStorage(PrefKey.ffDesktopLyrics)  private var desktopLyrics = false

    var body: some View {
        Section {
            Toggle(tr("Global Hotkeys", "全局热键"), isOn: $globalHotkeys)
                .tint(BrandColors.accent)
                .onChange(of: globalHotkeys) { _, _ in notify() }

            if globalHotkeys && capabilities.globalHotkeys != .supported {
                Text(tr("Some shortcuts could not be registered. Check for conflicting shortcuts in other apps.", "部分快捷键无法注册，请检查其他应用的快捷键冲突。", zhHant: "部分快捷鍵無法註冊，請檢查其他 App 的快捷鍵衝突。"))
                    .font(.caption).foregroundStyle(BrandColors.textPrimary)
            }

            Toggle(tr("Menu Bar Tray", "菜单栏托盘"), isOn: $tray)
                .tint(BrandColors.accent)
                .onChange(of: tray) { _, _ in notify() }

            Toggle(tr("Mini Player Window", "迷你播放器窗口"), isOn: $miniPlayer)
                .tint(BrandColors.accent)
                .onChange(of: miniPlayer) { _, _ in notify() }

            Toggle(tr("Desktop Lyrics Overlay", "桌面歌词悬浮层"), isOn: $desktopLyrics)
                .tint(BrandColors.accent)
                .onChange(of: desktopLyrics) { _, _ in notify() }

            Text(tr(
                "Output switching is limited to the macOS default device.",
                "输出切换受 macOS 默认设备限制。"
            ))
            .font(.caption)
            .foregroundStyle(BrandColors.textSecondary)
        } header: { Text(tr("Desktop Integration", "桌面集成")).font(.headline.weight(.semibold)) }
    }

    private func notify() {
        NotificationCenter.default.post(name: .musesDesktopFlagsChanged, object: nil)
    }
}
