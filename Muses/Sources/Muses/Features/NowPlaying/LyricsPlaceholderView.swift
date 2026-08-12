import SwiftUI

/// 歌词占位视图: 阶段 2 仅显示提示文案, 阶段 3 接入 LyricsService。
struct LyricsPlaceholderView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("无可用歌词").font(.title3).foregroundStyle(BrandColors.textPrimary)
            Text("点此搜索在线歌词").font(.callout).foregroundStyle(BrandColors.textSecondary)
            Text("(阶段 3 接入 LyricsService)").font(.caption).foregroundStyle(BrandColors.textSecondary.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}