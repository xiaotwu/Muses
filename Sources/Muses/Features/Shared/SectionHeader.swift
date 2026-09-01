import SwiftUI

/// Reusable section-header semantic primitive (per AGENTS.md "reusable primitives and semantic surface roles").
///
/// Large title (~18–22pt) with an optional ">" more affordance. Unifies the section-header rhythm of Home/New,
/// instead of scattering `Text().font(.title2)` and spacing across views.
struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    /// ">" more button; rendered as a tappable secondary control when non-nil.
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
