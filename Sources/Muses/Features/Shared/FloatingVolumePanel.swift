import AppKit
import SwiftUI

/// One capsule above the volume button, without a second rectangular popover.
/// Native menus inside retain their normal selection and keyboard behavior.
struct FloatingVolumePanel: View {
    var width: CGFloat
    var height: CGFloat
    var style: LiquidGlassVolumeBar.ScaleStyle = .graduated
    var dismiss: () -> Void

    var body: some View {
        LiquidGlassVolumeBar(width: width, height: height, focusesScaleOnAppear: true, scaleStyle: style)
            .background { VolumePanelDismissal(dismiss: dismiss) }
            .onExitCommand(perform: dismiss)
            .onKeyPress(.escape) { dismiss(); return .handled }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(tr("Volume", "音量"))
    }
}

private struct VolumePanelDismissal: NSViewRepresentable {
    let dismiss: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.dismiss = dismiss }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator {
        weak var view: NSView?
        var dismiss: () -> Void
        var monitor: Any?
        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }
        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let view = self.view, event.window?.level != .popUpMenu else { return }
                    let point = view.convert(event.locationInWindow, from: nil)
                    // The owning button handles its own toggle; do not close
                    // first and then reopen on that same mouse-down.
                    let anchor = NSRect(x: view.bounds.maxX - 40, y: -48, width: 40, height: 48)
                    if event.window !== view.window || (!view.bounds.contains(point) && !anchor.contains(point)) {
                        self.dismiss()
                    }
                }
                return event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}
