import SwiftUI

/// Shared empty-state component: icon + title + subtitle + optional next-step action.
struct EmptyStateView: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(MusesTypography.system(size: 48))
                .foregroundStyle(BrandColors.textSecondary)
            Text(title)
                .font(MusesTypography.title3)
                .foregroundStyle(BrandColors.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(MusesTypography.subheadline)
                    .foregroundStyle(BrandColors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle).padding(.horizontal, 14).frame(minHeight: 32)
                }
                    .buttonStyle(.musesCompact)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 80)
    }
}