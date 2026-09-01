import SwiftUI

/// Phase D4 — 可复用的区段标题语义原语(AGENTS.md "reusable primitives and semantic surface roles")。
///
/// 大标题 ~18–22pt,可选 ">" 更多 affordance。统一 Home/New 的区段头部节奏,
/// 避免在各视图散落 `Text().font(.title2)` 与间距。
struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    /// ">" 更多按钮;非 nil 时渲染为可点按的次要控件。
    var moreLabel: String? = nil
    var onMore: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.title2).fontWeight(.bold)
                    .foregroundStyle(BrandColors.textPrimary)
                Spacer(minLength: 0)
                if let moreLabel, let onMore {
                    Button(action: onMore) {
                        HStack(spacing: 3) {
                            Text(moreLabel)
                                .font(.subheadline)
                            Image(systemName: "chevron.right")
                                .font(.subheadline.bold())
                        }
                        .foregroundStyle(BrandColors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(moreLabel)
                }
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, AppleMusicTokens.contentPaddingX)
    }
}
