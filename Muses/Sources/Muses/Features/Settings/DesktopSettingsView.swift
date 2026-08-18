import SwiftUI

/// 桌面集成设置(Phase 24):全局热键 / 菜单栏托盘 / 迷你播放器 / 桌面歌词。
/// 各开关 `.onChange` 发 `.musesDesktopFlagsChanged` 通知,由 `MusesApp` 重新同步服务。
/// 默认全部关闭(Final Spec §15 隐私/不打扰),开启即生效,关闭即注销对应系统资源。
struct DesktopSettingsView: View {
    @AppStorage(PrefKey.ffGlobalHotkeys) private var globalHotkeys = false
    @AppStorage(PrefKey.ffTray)            private var tray = false
    @AppStorage(PrefKey.ffMiniPlayer)     private var miniPlayer = false
    @AppStorage(PrefKey.ffDesktopLyrics)  private var desktopLyrics = false

    var body: some View {
        Section(tr("Desktop Integration", "桌面集成")) {
            Toggle(tr("Global Hotkeys", "全局热键"), isOn: $globalHotkeys)
                .onChange(of: globalHotkeys) { _, _ in notify() }
            Text(tr("System-wide shortcuts (Play/Pause, Next, Previous, Like, Volume, Mini Player, Desktop Lyrics). Off by default.",
                    "系统级热键(播放/暂停、上一首/下一首、收藏、音量、迷你播放器、桌面歌词)。默认关闭。"))
                .font(.caption).foregroundStyle(BrandColors.textSecondary)

            Toggle(tr("Menu Bar Tray", "菜单栏托盘"), isOn: $tray)
                .onChange(of: tray) { _, _ in notify() }
            Text(tr("NSStatusItem tray with current track and quick controls. Off by default.",
                    "菜单栏托盘显示当前曲目与快捷控制。默认关闭。"))
                .font(.caption).foregroundStyle(BrandColors.textSecondary)

            Toggle(tr("Mini Player Window", "迷你播放器窗口"), isOn: $miniPlayer)
                .onChange(of: miniPlayer) { _, _ in notify() }
            Text(tr("Separate compact window sharing the same playback engine. Open via menu/hotkey/tray.",
                    "独立紧凑窗口,共享同一播放引擎。经菜单/热键/托盘打开。"))
                .font(.caption).foregroundStyle(BrandColors.textSecondary)

            Toggle(tr("Desktop Lyrics Overlay", "桌面歌词悬浮层"), isOn: $desktopLyrics)
                .onChange(of: desktopLyrics) { _, _ in notify() }
            Text(tr("Always-on-top floating lyrics reusing the same lyrics engine. Draggable; respects Reduce Motion.",
                    "常驻置顶歌词悬浮层,复用同一歌词引擎。可拖动;遵循「减弱动态效果」。"))
                .font(.caption).foregroundStyle(BrandColors.textSecondary)
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: .musesDesktopFlagsChanged, object: nil)
    }
}