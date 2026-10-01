import SwiftUI
import AppKit

/// Complete original Muses artwork without an application-drawn badge.
struct MusesMark: View {
    var size: CGFloat = 20

    var body: some View {
        if let image = TrayIcon.logoImage {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "music.note")
                .font(MusesTypography.system(size: size * 0.75, weight: .bold))
                .foregroundStyle(BrandColors.textPrimary)
                .frame(width: size, height: size)
        }
    }
}

/// The same transparent, monochrome brand silhouette as the macOS status item.
struct MusesSymbol: View {
    var size: CGFloat = 24

    var body: some View {
        Image(nsImage: TrayIcon.settingsImage)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
