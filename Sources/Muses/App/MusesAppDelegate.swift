import AppKit

/// Dock actions share the same facade as windows, menus and system media keys.
@MainActor
final class MusesAppDelegate: NSObject, NSApplicationDelegate {
    weak var playback: PlaybackService?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MusesSingleInstance.orderFrontMainWindow()
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let track = playback?.transportState.track {
            let title = NSMenuItem(title: track.title, action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            menu.addItem(.separator())
        }
        let active = playback?.transportState.track != nil
        add(playback?.transportState.isPlaying == true ? tr("Pause", "暂停") : tr("Play", "播放"),
            action: #selector(togglePlayback), enabled: active, to: menu)
        add(tr("Previous", "上一首"), action: #selector(previous),
            enabled: playback?.canGoPrevious == true, to: menu)
        add(tr("Next", "下一首"), action: #selector(next),
            enabled: playback?.canGoNext == true, to: menu)
        return menu
    }

    private func add(_ title: String, action: Selector, enabled: Bool, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    @objc private func togglePlayback() { playback?.toggle() }
    @objc private func previous() { playback?.previous() }
    @objc private func next() { playback?.next() }
}
