import AppKit
import ApplicationServices
import SwiftUI

struct ShortcutsSettingsView: View {
    @Environment(RuntimeCapabilities.self) private var capabilities
    @AppStorage(PrefKey.ffGlobalHotkeys) private var globalHotkeys = false
    @AppStorage(PrefKey.gestureClosePlayer) private var closePlayer = true
    @AppStorage(PrefKey.gestureChangeTrack) private var changeTrack = false
    @AppStorage(PrefKey.gestureShowLyrics) private var showLyrics = false

    var body: some View {
        Section {
            Toggle(tr("Global Hotkeys", "全局热键"), isOn: $globalHotkeys)
                .onChange(of: globalHotkeys) { _, _ in notify() }
            Text(tr("Control playback with ⌃⌘Space, previous with ⌃⌘←, and next with ⌃⌘→, even outside Muses.",
                    "在其他应用中也可使用 ⌃⌘空格控制播放，⌃⌘← 上一首，⌃⌘→ 下一首。"))
                .font(MusesTypography.caption).foregroundStyle(.secondary)
            if globalHotkeys && capabilities.globalHotkeys != .supported {
                Text(tr("Some shortcuts could not be registered. Check for conflicts in other apps.", "部分快捷键无法注册，请检查其他应用的快捷键冲突。"))
            }
            if globalHotkeys && capabilities.mediaKeys == .supported {
                Text(tr("Media keys ready · \(capabilities.mediaKeyPressCount) presses received",
                        "媒体键已就绪 · 已收到 \(capabilities.mediaKeyPressCount) 次按键"))
                    .font(MusesTypography.caption).foregroundStyle(.secondary)
            }
            if globalHotkeys && capabilities.mediaKeys != .supported {
                Text(tr("Keyboard media keys need Accessibility (Device Control and Data Access on newer macOS) permission. Return here after granting it; Muses reconnects automatically.",
                        "键盘媒体键需要辅助功能权限（新版 macOS 称为设备控制与数据访问）。授权后返回 Muses 即会自动连接。"))
                    .font(MusesTypography.caption).foregroundStyle(.secondary)
                Button(tr("Allow Media Keys…", "允许媒体键…")) {
                    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }.musesAction()
                Button(tr("Retry Media Keys", "重试媒体键")) { notify() }.musesAction()
            }
        } header: { Text(tr("Global Hotkeys", "全局热键")) }
        Section {
            Toggle(tr("Two-finger swipe down to close Now Playing", "双指下滑关闭正在播放"), isOn: $closePlayer)
            Toggle(tr("Two-finger swipe left / right for next / previous", "双指左滑／右滑切换下一首／上一首"), isOn: $changeTrack)
            Toggle(tr("Two-finger swipe up to show lyrics", "双指上滑显示歌词"), isOn: $showLyrics)
            Text(tr("Swipe over artwork or the player background. Lyrics, sliders, and other scrolling regions retain their own controls.",
                    "在封面或播放页背景上滑动；歌词、滑块和其他滚动区域保留原有操作。"))
                .font(MusesTypography.caption).foregroundStyle(.secondary)
        } header: { Text(tr("In-app Gestures", "应用内手势")) }
    }

    private func notify() {
        NotificationCenter.default.post(name: .musesDesktopFlagsChanged, object: nil)
    }
}
