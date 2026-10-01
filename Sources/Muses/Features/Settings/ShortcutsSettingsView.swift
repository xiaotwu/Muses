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
            Toggle(tr("Global shortcuts", "全局快捷键"), isOn: $globalHotkeys)
                .onChange(of: globalHotkeys) { _, _ in notify() }
            LabeledContent(tr("Play / pause", "播放／暂停")) {
                SettingsKeycaps(keys: ["⌃", "⌘", tr("Space", "空格")])
            }
            LabeledContent(tr("Previous", "上一首")) { SettingsKeycaps(keys: ["⌃", "⌘", "←"]) }
            LabeledContent(tr("Next", "下一首")) { SettingsKeycaps(keys: ["⌃", "⌘", "→"]) }
            if globalHotkeys && capabilities.globalHotkeys != .supported {
                SettingsStatus(title: tr("Shortcut conflict", "快捷键冲突"),
                               symbol: "exclamationmark.triangle", color: .orange)
                    .help(tr("Check shortcuts in other apps.", "请检查其他应用的快捷键。"))
            }
            if globalHotkeys {
                LabeledContent(tr("Media keys", "媒体键")) {
                    HStack(spacing: 8) {
                        SettingsStatus(title: capabilities.mediaKeys == .supported
                                       ? tr("Ready", "已就绪") : tr("Permission needed", "需要授权"),
                                       symbol: capabilities.mediaKeys == .supported ? "checkmark.circle" : "lock.shield")
                        if capabilities.mediaKeys != .supported {
                            Button(tr("Allow…", "授权…")) {
                                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .settingsAction()
                            .help(tr("Media keys require Accessibility permission.", "媒体键需要辅助功能权限。"))
                            SettingsIconButton(title: tr("Retry media keys", "重试媒体键"),
                                               symbol: "arrow.clockwise", action: notify)
                        }
                    }
                }
            }
        } header: { Text(tr("Keyboard", "键盘")) }
        Section {
            Toggle(isOn: $closePlayer) {
                Label(tr("Close Now Playing", "关闭正在播放"), systemImage: "arrow.down")
            }
            Toggle(isOn: $changeTrack) {
                Label(tr("Change track", "切歌"), systemImage: "arrow.left.arrow.right")
            }
            Toggle(isOn: $showLyrics) {
                Label(tr("Show lyrics", "显示歌词"), systemImage: "arrow.up")
            }
            DisclosureGroup(tr("Gesture area", "手势作用区域")) {
                Text(tr("Use two fingers over artwork or the player background. Lyrics, sliders and scrolling regions keep their own controls.",
                        "在封面或播放页背景上双指滑动。歌词、滑块和滚动区域保留原有操作。"))
                    .font(MusesTypography.caption).foregroundStyle(.secondary)
            }
        } header: { Text(tr("Two-finger gestures", "双指手势")) }
    }

    private func notify() {
        NotificationCenter.default.post(name: .musesDesktopFlagsChanged, object: nil)
    }
}
