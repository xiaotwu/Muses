import SwiftUI
import AppKit
import ApplicationServices

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
            Toggle(tr("Menu Bar Tray", "菜单栏托盘"), isOn: $tray)
                .tint(BrandColors.accent)
                .onChange(of: tray) { _, _ in notify() }

            Toggle(tr("Mini Player Window", "迷你播放器窗口"), isOn: $miniPlayer)
                .tint(BrandColors.accent)
                .onChange(of: miniPlayer) { _, _ in notify() }

            Toggle(tr("Desktop Lyrics Overlay", "桌面歌词悬浮层"), isOn: $desktopLyrics)
                .tint(BrandColors.accent)
                .onChange(of: desktopLyrics) { _, _ in notify() }

        } header: { Text(tr("Desktop Integration", "桌面集成")).font(MusesTypography.headline.weight(.semibold)) }
    }

    private func notify() {
        NotificationCenter.default.post(name: .musesDesktopFlagsChanged, object: nil)
    }
}

struct CollectionAccessibilitySettingsView: View {
    @AppStorage(PrefKey.accessibleCollectionTables) private var pagedTables = false

    var body: some View {
        Section {
            Toggle(tr("Paged song tables", "分页歌曲表格"), isOn: $pagedTables)
        } header: { Text(tr("Accessibility", "辅助功能")) }
        footer: {
            Text(tr("25 songs per page. Enabled automatically with VoiceOver.",
                    "每页 25 首，VoiceOver 开启时自动启用。"))
        }
    }
}
