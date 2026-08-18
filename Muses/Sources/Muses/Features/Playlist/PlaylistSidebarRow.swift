import SwiftUI

/// 侧边栏合并歌单行:本地歌单或 YouTube 导入歌单。
///
/// YouTube 项在名称左侧显示一个克制的小型 YouTube 来源图标(单色 `play.rectangle`,
/// 与侧边栏图标 baseline 对齐),不抢名称、不引入品牌红色块。
/// 点击通过既有通知路由:本地 → `.musesSelectPlaylist`;YouTube → `.musesNavigateYouTubeImport`。
/// 路由所需的对象引用由持有 `@Model` 集合的父视图在点击时解析(此处仅按 id 触发),
/// 以保持本行视图轻量、可在 `ForEach` 中复用且不持有 @Model 强引用。
struct PlaylistSidebarRow: View {
    let item: SidebarPlaylistItem
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if item.isYouTube {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(BrandColors.textSecondary)
                    .accessibilityHidden(true)
            }
            Text(item.name)
                .lineLimit(1)
                .foregroundStyle(BrandColors.textPrimary)
        }
        .tag(SidebarSection.playlists)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        item.isYouTube
            ? tr("\(item.name), YouTube playlist", "\(item.name),YouTube 歌单")
            : tr("\(item.name), playlist", "\(item.name),歌单")
    }
}