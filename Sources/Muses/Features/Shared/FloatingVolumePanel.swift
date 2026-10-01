import AppKit
import SwiftUI

/// A native child panel owns pointer input across the entire capsule, including
/// the portion outside the presenting button's SwiftUI layout bounds.
struct FloatingVolumePanel: View {
    @Environment(PlaybackService.self) private var playback
    @Environment(AudioDeviceService.self) private var audioDevices: AudioDeviceService?
    @Environment(\.colorScheme) private var colorScheme
    var width: CGFloat
    var height: CGFloat
    var style: LiquidGlassVolumeBar.ScaleStyle = .graduated
    var dismiss: () -> Void

    var body: some View {
        VolumePanelHost(width: width, height: height, dismiss: dismiss, keyAction: { key in
            switch key {
            case 123: playback.setVolume(max(0, playback.volume - 0.05)); return true
            case 124: playback.setVolume(min(1, playback.volume + 0.05)); return true
            default: return false
            }
        }) {
            LiquidGlassVolumeBar(width: width, height: height,
                                 focusesScaleOnAppear: true, scaleStyle: style)
                .environment(playback)
                .environment(audioDevices)
                .preferredColorScheme(colorScheme)
                .onExitCommand(perform: dismiss)
                .onKeyPress(.escape) { dismiss(); return .handled }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(tr("Volume", "音量"))
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }
}

private struct VolumePanelHost<Content: View>: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat
    let dismiss: () -> Void
    let keyAction: (UInt16) -> Bool
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss, keyAction: keyAction) }
    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onLayout = { [weak coordinator = context.coordinator] in coordinator?.position() }
        context.coordinator.anchor = view
        context.coordinator.panel.contentView = NSHostingView(rootView: content())
        context.coordinator.install()
        return view
    }
    func updateNSView(_ view: AnchorView, context: Context) {
        context.coordinator.dismiss = dismiss
        context.coordinator.keyAction = keyAction
        (context.coordinator.panel.contentView as? NSHostingView<Content>)?.rootView = content()
        context.coordinator.position()
    }
    static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
        view.onLayout = nil
        coordinator.stop()
    }

    final class AnchorView: NSView {
        var onLayout: (() -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onLayout?() }
        override func layout() { super.layout(); onLayout?() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    final class CapsulePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    @MainActor final class Coordinator {
        weak var anchor: AnchorView?
        let panel: CapsulePanel
        var dismiss: () -> Void
        var keyAction: (UInt16) -> Bool
        var monitor: Any?
        var dismissOnMouseUp = false
        var resignObserver: NSObjectProtocol?
        init(dismiss: @escaping () -> Void, keyAction: @escaping (UInt16) -> Bool) {
            self.dismiss = dismiss
            self.keyAction = keyAction
            panel = CapsulePanel(contentRect: .zero,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            panel.title = tr("Volume", "音量")
            panel.setAccessibilityLabel(tr("Volume", "音量"))
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = true
            panel.animationBehavior = .none
            panel.isMovableByWindowBackground = false
        }
        func position() {
            guard let anchor, let parent = anchor.window,
                  anchor.bounds.width > 0, anchor.bounds.height > 0 else { return }
            let rect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            panel.setFrame(rect, display: true)
            if panel.parent !== parent {
                panel.parent?.removeChildWindow(panel)
                parent.addChildWindow(panel, ordered: .above)
            }
            if !panel.isVisible { panel.makeKeyAndOrderFront(nil) }
        }
        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp, .keyDown]) { [weak self] event in
                let consume = MainActor.assumeIsolated {
                    guard let self else { return false }
                    if event.type == .keyDown, self.panel.isVisible,
                       event.window?.level != .popUpMenu {
                        if event.keyCode == 53 { self.dismiss(); return true }
                        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                            return self.keyAction(event.keyCode)
                        }
                        return false
                    }
                    if self.dismissOnMouseUp, event.type == .leftMouseUp || event.type == .rightMouseUp {
                        self.dismissOnMouseUp = false
                        self.dismiss()
                        return true
                    }
                    guard event.type == .leftMouseDown || event.type == .rightMouseDown,
                          self.panel.isVisible, event.window !== self.panel,
                          event.window?.level != .popUpMenu else { return false }
                    let consume = event.window === self.panel.parent
                    // Keep the monitor through mouse-up: SwiftUI controls can
                    // otherwise receive the release after their down was eaten.
                    if consume { self.dismissOnMouseUp = true }
                    else { self.dismiss() }
                    return consume
                }
                return consume ? nil : event
            }
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            resignObserver = nil
            let parent = panel.parent
            let wasKey = panel.isKeyWindow
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
            if wasKey { parent?.makeKey() }
        }
    }
}
