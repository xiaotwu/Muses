import SwiftUI

/// Floating lyrics panel, matching sidebar / queue chrome height.
struct LyricsDrawerView: View {
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "quote.bubble")
                    .foregroundStyle(BrandColors.textSecondary)
                Spacer()
                ChromeIconButton(
                    systemName: "xmark",
                    help: tr("Close", "关闭"),
                    accessibility: tr("Close lyrics", "关闭歌词")
                ) { isPresented = false }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            LyricsView()
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .musesFloatingChrome(cornerRadius: 18)
        .onExitCommand { isPresented = false }
    }
}
