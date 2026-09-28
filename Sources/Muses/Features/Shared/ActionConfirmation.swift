import SwiftUI

/// Presentation-owned request. Menu items enqueue it; only the window's
/// explicit confirmation executes the action. Cancel and Escape discard it.
struct ActionConfirmation {
    let title: String
    let message: String
    var actionTitle = tr("Delete", "删除")
    var destructive = true
    let action: @MainActor () -> Void
}

private struct ActionConfirmationModifier: ViewModifier {
    @Binding var request: ActionConfirmation?

    func body(content: Content) -> some View {
        content.alert(request?.title ?? "", isPresented: Binding(
            get: { request != nil },
            set: { if !$0 { request = nil } }
        ), presenting: request) { presented in
            Button(presented.actionTitle, role: presented.destructive ? .destructive : nil) {
                request = nil
                presented.action()
            }
            Button(tr("Cancel", "取消"), role: .cancel) { request = nil }
        } message: { presented in
            Text(presented.message)
        }
    }
}

extension View {
    func actionConfirmation(_ request: Binding<ActionConfirmation?>) -> some View {
        modifier(ActionConfirmationModifier(request: request))
    }
}
