import Foundation

/// Centralized command registry: maps "command id → handler closure" so app menu shortcuts,
/// PlayerBar buttons, context menus, and global hotkeys all invoke the same logic.
/// Only existing commands are registered here; no new behavior is introduced.
///
/// Usage: after `MusesApp.init` constructs it, register commands with `register(...)`;
/// menu buttons / hotkeys invoke them via `execute(...)`. A future command palette
/// can also enumerate commands from this registry.
@Observable
@MainActor
final class CommandRegistry {
    /// Command identifiers (strings for extensibility; may become a strongly typed enum later).
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