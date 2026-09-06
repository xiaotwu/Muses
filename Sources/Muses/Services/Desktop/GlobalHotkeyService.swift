import Foundation
import Carbon.HIToolbox
import Observation

/// Global hotkey service (Final Spec §10.1 Feature 1 — Native Desktop).
///
/// Registers system-wide hotkeys via Carbon `RegisterEventHotKey` and forwards them to
/// `CommandRegistry` action ids. Feature flag `PrefKey.ffGlobalHotkeys` (off by default):
/// turning it off unregisters all hotkeys.
///
/// **Testability:** shortcut encode/decode/conflict detection are pure functions
/// (`HotkeyShortcut` + `Self.conflicts`). Carbon registration itself fails in headless
/// environments without an application event target → it is only logged and skipped,
/// never reported as fake success. The `UInt32 id → action` mapping needed for dispatch
/// lives in a static table that the C callback (which has no captured context) looks up.
@Observable
@MainActor
final class GlobalHotkeyService {
    /// Action ids (reusing existing CommandRegistry commands plus desktop-specific ones).
    static let actionPlayPause       = CommandRegistry.togglePlayback
    static let actionNext            = CommandRegistry.next
    static let actionPrevious        = CommandRegistry.previous
    static let actionLike            = CommandRegistry.likeCurrent
    static let actionVolumeUp        = "desktop.volumeUp"
    static let actionVolumeDown      = "desktop.volumeDown"
    static let actionMute            = "desktop.mute"
    static let actionAddToInbox      = "desktop.addToInbox"
    static let actionShowHidePlayer  = "desktop.showHidePlayer"
    static let actionShowMiniPlayer  = "desktop.showMiniPlayer"
    static let actionShowLyrics      = "desktop.showLyrics"
    static let actionToggleFocus     = "desktop.toggleFocusMode"

    /// Default bindings (restorable via "Reset to Defaults"). Key codes are Carbon virtualKeys; modifiers are Carbon modifierFlags.
    static let defaults: [String: HotkeyShortcut] = [
        actionPlayPause:      HotkeyShortcut(keyCode: kVK_Space, modifiers: cmdKey | controlKey),
        actionNext:           HotkeyShortcut(keyCode: kVK_RightArrow, modifiers: cmdKey | controlKey),
        actionPrevious:       HotkeyShortcut(keyCode: kVK_LeftArrow, modifiers: cmdKey | controlKey),
        actionLike:           HotkeyShortcut(keyCode: kVK_ANSI_L, modifiers: cmdKey | controlKey | optionKey),
        actionVolumeUp:       HotkeyShortcut(keyCode: kVK_UpArrow, modifiers: cmdKey | controlKey),
        actionVolumeDown:     HotkeyShortcut(keyCode: kVK_DownArrow, modifiers: cmdKey | controlKey),
        actionMute:           HotkeyShortcut(keyCode: kVK_ANSI_M, modifiers: cmdKey | controlKey | optionKey),
        actionAddToInbox:     HotkeyShortcut(keyCode: kVK_ANSI_I, modifiers: cmdKey | controlKey | optionKey),
        actionShowHidePlayer: HotkeyShortcut(keyCode: kVK_ANSI_P, modifiers: cmdKey | controlKey | optionKey),
        actionShowMiniPlayer: HotkeyShortcut(keyCode: kVK_ANSI_O, modifiers: cmdKey | controlKey | optionKey),
        actionShowLyrics:     HotkeyShortcut(keyCode: kVK_ANSI_Y, modifiers: cmdKey | controlKey | optionKey),
        actionToggleFocus:    HotkeyShortcut(keyCode: kVK_ANSI_F, modifiers: cmdKey | controlKey | optionKey)
    ]

    /// Display names of all bindable actions (listed by the settings panel).
    static let actionLabels: [String: String] = [
        actionPlayPause: "Play / Pause", actionNext: "Next", actionPrevious: "Previous",
        actionLike: "Like", actionVolumeUp: "Volume Up", actionVolumeDown: "Volume Down",
        actionMute: "Mute", actionAddToInbox: "Add to Inbox",
        actionShowHidePlayer: "Show / Hide Player", actionShowMiniPlayer: "Show Mini Player",
        actionShowLyrics: "Show Desktop Lyrics", actionToggleFocus: "Toggle Focus Mode"
    ]

    private let enabledProvider: () -> Bool
    private let shortcutProvider: () -> [String: HotkeyShortcut]
    private let dispatcher: (String) -> Void
    private var registered: [(EventHotKeyRef, UInt32)] = []
    private var eventHandler: EventHandlerRef?
    private var nextHotKeyId: UInt32 = 1
    private(set) var revision: Int = 0
    var isEnabled: Bool { enabledProvider() }

    init(enabledProvider: @escaping () -> Bool = {
        UserDefaults.standard.bool(forKey: PrefKey.ffGlobalHotkeys)
    },
         shortcutProvider: @escaping () -> [String: HotkeyShortcut] = {
        GlobalHotkeyService.loadShortcuts()
    },
         dispatcher: @escaping (String) -> Void = { _ in }) {
        self.enabledProvider = enabledProvider
        self.shortcutProvider = shortcutProvider
        self.dispatcher = dispatcher
    }

    // MARK: - State sync

    /// Re-reads the flag and bindings, then re-registers. Flag off → unregister everything.
    func sync() {
        unregisterAll()
        guard isEnabled else { revision &+= 1; return }
        let map = shortcutProvider()
        installEventHandlerIfNeeded()
        for (action, sc) in map {
            let id = nextHotKeyId; nextHotKeyId &+= 1
            Self.actionById[id] = action
            var ref: EventHotKeyRef?
            let hotKeyId = EventHotKeyID(signature: fourCharCode("Muss"), id: id)
            let status = RegisterEventHotKey(UInt32(sc.keyCode), UInt32(sc.modifiers), hotKeyId,
                                              GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registered.append((ref, id))
            } else {
                AppLog.for("GlobalHotkeyService").warning("Failed to register hotkey action=\(action) status=\(status)")
                Self.actionById.removeValue(forKey: id)
            }
        }
        revision &+= 1
    }

    private func unregisterAll() {
        for (ref, id) in registered {
            UnregisterEventHotKey(ref)
            Self.actionById.removeValue(forKey: id)
        }
        registered.removeAll()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var handler: EventHandlerRef?
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                  eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), musesHotkeyCallback, 1, &spec,
                                          nil, &handler)
        if status == noErr { eventHandler = handler }
    }

    // MARK: - C callback (no captured context → static lookup table)

    /// Static id → action mapping (a C callback cannot capture self).
    nonisolated(unsafe) static var actionById: [UInt32: String] = [:]
    /// Injected with `dispatcher` by production wiring; the C callback cannot capture self,
    /// so it goes through this static singleton pointer.
    nonisolated(unsafe) static var sharedDispatcher: ((String) -> Void)?

    // MARK: - Persistence (JSON)

    static func loadShortcuts() -> [String: HotkeyShortcut] {
        guard let data = UserDefaults.standard.data(forKey: PrefKey.globalHotkeys),
              let map = try? JSONDecoder().decode([String: HotkeyShortcut].self, from: data),
              !map.isEmpty else {
            return defaults
        }
        return map
    }

    static func saveShortcuts(_ map: [String: HotkeyShortcut]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: PrefKey.globalHotkeys)
    }

    /// Conflict detection: the same shortcut claimed by multiple actions → returns [shortcut : [actions]].
    static func conflicts(_ map: [String: HotkeyShortcut]) -> [HotkeyShortcut: [String]] {
        var groups: [HotkeyShortcut: [String]] = [:]
        for (action, sc) in map { groups[sc, default: []].append(action) }
        return groups.filter { $0.value.count > 1 }
    }

    // MARK: - helpers

    private func fourCharCode(_ s: String) -> OSType {
        let bytes = Array(s.utf8) + [0, 0, 0, 0]
        return OSType(bytes[0]) << 24 | OSType(bytes[1]) << 16
             | OSType(bytes[2]) << 8 | OSType(bytes[3])
    }
}

/// Top-level `@convention(c)` callback: Carbon event handlers cannot capture context, so this looks up the static table and dispatches on the main thread.
@_cdecl("musesHotkeyCallback")
private func musesHotkeyCallback(_ callRef: OpaquePointer?, _ event: OpaquePointer?,
                                  _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return noErr }
    var id: UInt32 = 0
    GetEventParameter(event, EventParamName(kEventParamDirectObject),
                      EventParamType(typeEventHotKeyID), nil,
                      MemoryLayout<UInt32>.size, nil, &id)
    guard let action = GlobalHotkeyService.actionById[id] else { return noErr }
    let dispatcher = GlobalHotkeyService.sharedDispatcher
    Task { @MainActor in dispatcher?(action) }
    return noErr
}

/// A global hotkey shortcut (keyCode + modifiers, both Int to match Carbon constants). A pure Codable/Sendable/Equatable value, easy to test.
struct HotkeyShortcut: Codable, Sendable, Equatable, Hashable {
    let keyCode: Int
    let modifiers: Int
}