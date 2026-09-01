import SwiftUI

/// Responsive horizontal carousel: visible card count grows with window width instead of a rigid max-width.
///
/// Unlike a fixed-column grid, the carousel always scrolls horizontally while `cardSize` adapts to the available width,
/// avoiding stretched cards or large empty gaps on wide screens. `spacing`/`horizontalPadding` match the existing
/// section rhythm (24pt margins).
struct ResponsiveCarousel<Content: View>: View {
    let cardSize: CGFloat
    let spacing: CGFloat
    let horizontalPadding: CGFloat
    let alignment: VerticalAlignment
    let content: () -> Content

    init(cardSize: CGFloat,
         spacing: CGFloat = 16,
         horizontalPadding: CGFloat = AppleMusicTokens.contentPaddingX,
         alignment: VerticalAlignment = .center,
         @ViewBuilder content: @escaping () -> Content) {
        self.cardSize = cardSize
        self.spacing = spacing
        self.horizontalPadding = horizontalPadding
        self.alignment = alignment
        self.content = content
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: alignment, spacing: spacing) {
                content()
            }
            .padding(.horizontal, horizontalPadding)
        }
    }
}
