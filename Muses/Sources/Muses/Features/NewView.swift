import SwiftUI

/// New 页面占位:推荐功能即将上线。
struct NewView: View {
    var body: some View {
        EmptyStateView(
            icon: "sparkles",
            title: tr("Coming Soon", "即将推出"),
            subtitle: tr("Recommendations will appear here", "推荐功能即将上线")
        )
        .background(BrandColors.background)
    }
}