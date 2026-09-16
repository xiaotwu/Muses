import AppKit
import SwiftUI

/// Keep native table state alive while excluding the inactive surface from
/// rendering, hit testing, first-responder navigation and the AppKit AX tree.
struct RetainedCollectionSurface<Content: View>: NSViewRepresentable {
    let isVisible: Bool
    let content: Content

    init(isVisible: Bool, @ViewBuilder content: () -> Content) {
        self.isVisible = isVisible
        // Evaluate while the parent body tracks state dependencies. Deferring
        // this closure into AppKit can retain stale interaction modifiers.
        self.content = content()
    }

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: root(context))
        host.sizingOptions = []
        host.isHidden = !isVisible
        return host
    }

    func updateNSView(_ host: NSHostingView<AnyView>, context: Context) {
        host.rootView = root(context)
        if !isVisible, let responder = host.window?.firstResponder as? NSView,
           responder.isDescendant(of: host) {
            host.window?.makeFirstResponder(nil)
        }
        host.isHidden = !isVisible
    }

    private func root(_ context: Context) -> AnyView {
        AnyView(content.environment(\.self, context.environment))
    }
}
