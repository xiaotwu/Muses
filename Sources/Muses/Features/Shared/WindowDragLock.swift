import SwiftUI
import AppKit

/// Prevents a hidden-titlebar window from treating slider drags as window moves.
final class WindowMoveBlockerView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

struct WindowMoveBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowMoveBlockerView {
        WindowMoveBlockerView()
    }

    func updateNSView(_ nsView: WindowMoveBlockerView, context: Context) {}
}

extension View {
    /// Put behind sliders and other drag controls so they do not drag the window.
    func blocksWindowDrag() -> some View {
        background(WindowMoveBlocker())
    }
}
