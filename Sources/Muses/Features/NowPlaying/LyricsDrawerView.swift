import SwiftUI

/// Integrated trailing lyrics panel, matching Queue chrome styling and titlebar clearance.
struct LyricsDrawerView: View {
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            LyricsView()
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        .musesGlass(in: Rectangle(), role: .persistentChrome)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(BrandColors.hairline)
                .frame(width: 1)
        }
        .onExitCommand { isPresented = false }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(BrandColors.magenta)
            Text(tr("Lyrics", "歌词"))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(BrandColors.textPrimary)
            Spacer()
            ChromeIconButton(
                systemName: "xmark",
                help: tr("Close", "关闭"),
                accessibility: tr("Close lyrics", "关闭歌词")
            ) { isPresented = false }
        }
        .padding(.horizontal, 16)
        .padding(.top, WindowChromeMetrics.trafficLightClearanceHeight + 8)
        .padding(.bottom, 12)
    }
}
