import Foundation
import Carbon.HIToolbox
import Observation

/// 全局热键服务(Final Spec §10.1 Feature 1 — Native Desktop)。
///
/// 通过 Carbon `RegisterEventHotKey` 注册系统级热键,转发到 `CommandRegistry` action id。
/// 功能开关 `PrefKey.ffGlobalHotkeys`(默认关):关闭即注销全部热键。
///
/// **可测试性:** 快捷键的编码/解码/冲突检测均为纯函数(`HotkeyShortcut` + `Self.conflicts`),
/// Carbon 注册本身在无应用事件目标的 headless 环境会失败 → 仅记日志并跳过,绝不伪造成功。
/// 注册所需的 `UInt32 id → action` 映射放在静态表里,供 C 回调(无捕获上下文)查表派发。
@Observable
@MainActor
final class GlobalHotkeyService {
    /// 动作 id(复用 CommandRegistry 现有 + Phase 24 新增桌面动作)。
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

    /// 默认绑定(可「恢复默认」)。键码为 Carbon virtualKey;修饰为 Carbon modifierFlags。
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

    /// 所有可绑定动作的展示名(供设置面板列出)。
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

    // MARK: - 状态同步

    /// 重新读取开关 + 绑定,重注册。开关关 → 注销全部。
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
                AppLog.for("GlobalHotkeyService").warning("注册热键失败 action=\(action) status=\(status)")
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

    // MARK: - C 回调(无捕获上下文 → 静态查表)

    /// id → action 的静态映射(C 回调无法捕获 self)。
    nonisolated(unsafe) static var actionById: [UInt32: String] = [:]
    /// 由生产接线注入 `dispatcher`;C 回调不可捕获 self,故走静态单例指针。
    nonisolated(unsafe) static var sharedDispatcher: ((String) -> Void)?

    // MARK: - 持久化(JSON)

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

    /// 冲突检测:同一快捷键被多个动作占用 → 返回 [快捷键 : [动作]]。
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

/// 顶层 `@convention(c)` 回调:Carbon 事件处理函数不可捕获上下文,故查静态表后跳主线程派发。
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

/// 全局热键快捷键(keyCode + 修饰键,均用 Int 以匹配 Carbon 常量),Codable/Sendable/Equatable,纯值,便于测试。
struct HotkeyShortcut: Codable, Sendable, Equatable, Hashable {
    let keyCode: Int
    let modifiers: Int
}