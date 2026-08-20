import SwiftUI
import AppKit

/// Apple Music–style wordmark: 20pt rounded mark + “Muses” text.
struct MusesWordmark: View {
    var body: some View {
        HStack(spacing: 6) {
            mark
            if MusesWordmarkMetrics.showsText {
                Text("Muses")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(BrandColors.textPrimary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Muses")
    }

    @ViewBuilder
    private var mark: some View {
        let size = MusesWordmarkMetrics.icon
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        if let url = Bundle.main.url(forResource: "logo", withExtension: "png")
            ?? Bundle.module.url(forResource: "logo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(shape)
        } else {
            shape
                .fill(BrandColors.textPrimary)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(BrandColors.background)
                }
        }
    }
}
