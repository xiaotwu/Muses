import SwiftUI

/// Phase D4 — 响应式横向轮播:可见卡片数随窗口宽度增长,无死板 max-width(§4)。
///
/// 与固定列数网格不同,轮播始终横向滚动,但 `cardSize` 可由调用方按可用宽度自适应,
/// 避免宽屏下卡片被拉伸到失真或留大片空白。`spacing`/`horizontalPadding` 与既有
/// 区段一致(24pt 边距)。
struct ResponsiveCarousel<Content: View>: View {
    let cardSize: CGFloat
    let spacing: CGFloat
    let horizontalPadding: CGFloat
    let content: () -> Content

    init(cardSize: CGFloat,
         spacing: CGFloat = 16,
         horizontalPadding: CGFloat = 24,
         @ViewBuilder content: @escaping () -> Content) {
        self.cardSize = cardSize
        self.spacing = spacing
        self.horizontalPadding = horizontalPadding
        self.content = content
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                content()
            }
            .padding(.horizontal, horizontalPadding)
        }
    }
}