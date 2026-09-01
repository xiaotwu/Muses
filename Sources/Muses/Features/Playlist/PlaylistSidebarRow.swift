import SwiftUI

/// Merged sidebar playlist row: a local playlist or a YouTube import.
///
/// YouTube items show a restrained, small `YouTubeMark` before the name, aligned to the sidebar icon baseline.
/// Tapping routes through existing notifications: local → `.musesSelectPlaylist`; YouTube → `.musesNavigateYouTubeImport`.
/// The object references needed for routing are resolved at tap time by the parent view that owns the `@Model` collections (this row fires by id only),
/// keeping this row lightweight, reusable in `ForEach`, and free of strong @Model references.
struct PlaylistSidebarRow: View {
    let item: SidebarPlaylistItem
    var isSelected: Bool = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                if item.isYouTube {
                    YouTubeMark(size: 12)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                }
                Text(item.name)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? BrandColors.magenta : BrandColors.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: AppleMusicTokens.navItemHeight, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? BrandColors.textPrimary.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accessibilityLabel: String {
        item.isYouTube
            ? tr("\(item.name), YouTube playlist", "\(item.name),YouTube 歌单")
            : tr("\(item.name), playlist", "\(item.name),歌单")
    }
}
