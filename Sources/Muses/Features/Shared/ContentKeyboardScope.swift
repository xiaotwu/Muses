import AppKit

/// Unmodified browsing/playback keys must not consume text or sheet input.
@MainActor
enum ContentKeyboardScope {
    static var acceptsShortcuts: Bool {
        guard let window = NSApp.keyWindow,
              window.sheetParent == nil, window.attachedSheet == nil else { return false }
        return !(window.firstResponder is NSTextView)
    }
}
