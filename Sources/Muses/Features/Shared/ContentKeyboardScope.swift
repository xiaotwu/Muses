import AppKit

/// Unmodified browsing/playback keys must not consume text or sheet input.
@MainActor
enum ContentKeyboardScope {
    static var acceptsShortcuts: Bool {
        guard let window = NSApp.keyWindow,
              window.sheetParent == nil, window.attachedSheet == nil else { return false }
        return acceptsShortcuts(
            firstResponderIsTextInput: window.firstResponder is NSTextView,
            hasPresentedSheet: false
        )
    }

    nonisolated static func acceptsShortcuts(
        firstResponderIsTextInput: Bool,
        hasPresentedSheet: Bool
    ) -> Bool {
        !firstResponderIsTextInput && !hasPresentedSheet
    }
}
