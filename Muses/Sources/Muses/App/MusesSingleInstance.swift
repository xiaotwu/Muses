import AppKit

/// Same bundle ID can still launch twice from different `.app` paths (dev builds /
/// worktrees). The second process must not open the SwiftData store.
enum MusesSingleInstance {
    static let mainWindowAutosaveName = "MusesMainWindow"
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("Muses.main-window")

    static func shouldYield(otherPids: [pid_t], currentPid: pid_t) -> Bool {
        otherPids.contains { $0 != currentPid && $0 > 0 }
    }

    /// Activate the already-running copy and abort this process *before* opening
    /// the active YouTube-native store. Safe to call from `MusesApp.init`.
    static func yieldIfOtherInstanceRunning(
        bundleId: String? = Bundle.main.bundleIdentifier,
        currentPid: pid_t = ProcessInfo.processInfo.processIdentifier
    ) {
        guard let bundleId else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != currentPid }
        guard let existing = others.first else { return }
        existing.activate(options: [.activateAllWindows])
        Darwin.exit(0)
    }

    @MainActor
    static func isMainWindow(_ window: NSWindow) -> Bool {
        window.identifier == mainWindowIdentifier
            || window.frameAutosaveName == mainWindowAutosaveName
    }

    @MainActor
    static func mainWindow(in windows: [NSWindow]) -> NSWindow? {
        windows.first(where: isMainWindow)
    }

    /// Brings forward only the configured browse window. Auxiliary Search and
    /// Mini Player windows must never be promoted into the main-window role.
    @MainActor
    @discardableResult
    static func orderFrontMainWindow() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = mainWindow(in: NSApp.windows) else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// Idempotent main-window configuration. Standard traffic-light buttons
    /// remain in AppKit's native titlebar hierarchy.
    @MainActor
    static func configureMainWindow(_ window: NSWindow) {
        window.identifier = mainWindowIdentifier
        window.setFrameAutosaveName(mainWindowAutosaveName)
        window.isMovableByWindowBackground = true
        // Keep one stable semantic title for Window-menu and accessibility use;
        // route changes must never surface a destination label in the titlebar.
        window.title = "Muses"
        window.subtitle = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = .none
        window.toolbar?.isVisible = false
        window.contentMinSize = NSSize(
            width: WindowChromeMetrics.minimumWidth,
            height: WindowChromeMetrics.minimumHeight
        )
        for type in [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton
        ] {
            window.standardWindowButton(type)?.isHidden = false
        }
    }
}
