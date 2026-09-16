import SwiftUI
import AppKit

/// Complete original Muses artwork without an application-drawn badge.
struct MusesMark: View {
    var size: CGFloat = 20

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: max(4, size * 0.22), style: .continuous)
        if let image = TrayIcon.logoImage {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            shape
                .fill(BrandColors.textPrimary)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.5, weight: .bold))
                        .foregroundStyle(BrandColors.background)
                }
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
