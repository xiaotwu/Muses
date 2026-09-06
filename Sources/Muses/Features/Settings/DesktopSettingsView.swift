import SwiftUI

/// Desktop integration settings: global hotkeys / menu bar tray / mini player / desktop lyrics.
/// Each toggle's `.onChange` posts `.musesDesktopFlagsChanged`, which `MusesApp` uses to re-sync services.
/// Everything defaults to off (privacy-first / non-intrusive); enabling takes effect immediately and disabling releases the system resources.
struct DesktopSettingsView: View {
    @AppStorage(PrefKey.ffGlobalHotkeys) private var globalHotkeys = false
    @AppStorage(PrefKey.ffTray)            private var tray = true
    @AppStorage(PrefKey.ffMiniPlayer)     private var miniPlayer = false
    @AppStorage(PrefKey.ffDesktopLyrics)  private var desktopLyrics = false

    var body: some View {
        Section(tr("Desktop Integration", "桌面集成")) {
            Toggle(tr("Global Hotkeys", "全局热键"), isOn: $globalHotkeys)
                .tint(BrandColors.magenta)
                .onChange(of: globalHotkeys) { _, _ in notify() }

            Toggle(tr("Menu Bar Tray", "菜单栏托盘"), isOn: $tray)
                .tint(BrandColors.magenta)
                .onChange(of: tray) { _, _ in notify() }

            Toggle(tr("Mini Player Window", "迷你播放器窗口"), isOn: $miniPlayer)
                .tint(BrandColors.magenta)
                .onChange(of: miniPlayer) { _, _ in notify() }

            Toggle(tr("Desktop Lyrics Overlay", "桌面歌词悬浮层"), isOn: $desktopLyrics)
                .tint(BrandColors.magenta)
                .onChange(of: desktopLyrics) { _, _ in notify() }
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: .musesDesktopFlagsChanged, object: nil)
    }
}