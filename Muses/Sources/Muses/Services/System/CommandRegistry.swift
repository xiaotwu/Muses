import Foundation

/// 集中式命令注册表:把"命令 id → 处理闭包"集中,使应用菜单快捷键、PlayerBar 按钮、
/// 上下文菜单与 Phase 24 全局热键调用同一处理逻辑。Phase 16 仅注册已有命令,不新增行为。
///
/// 用法:`MusesApp.init` 构造后用 `register(...)` 注册;菜单按钮 / 热键用 `execute(...)`
/// 调用。命令面板(未来)也可基于此注册表枚举命令。
@Observable
@MainActor
final class CommandRegistry {
    /// 命令标识(字符串,便于扩展;未来可换为强类型 enum)。
    static let togglePlayback = "player.togglePlayback"
    static let next = "player.next"
    static let previous = "player.previous"
    static let likeCurrent = "library.likeCurrent"
    static let toggleQueue = "ui.toggleQueue"
    static let focusSearch = "ui.focusSearch"

    private var handlers: [String: () -> Void] = [:]
    private var enabledChecks: [String: () -> Bool] = [:]

    func register(_ id: String, handler: @escaping () -> Void,
                  enabled: @escaping () -> Bool = { true }) {
        handlers[id] = handler
        enabledChecks[id] = enabled
    }

    func execute(_ id: String) {
        guard let h = handlers[id] else { return }
        h()
    }

    func isEnabled(_ id: String) -> Bool {
        enabledChecks[id]?() ?? false
    }

    func has(_ id: String) -> Bool { handlers[id] != nil }
}