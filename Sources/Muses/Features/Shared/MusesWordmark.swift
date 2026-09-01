import SwiftUI
import AppKit

/// Rounded Muses mark used by the idle player capsule.
struct MusesMark: View {
    var size: CGFloat = 20

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: max(4, size * 0.22), style: .continuous)
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
                        .font(.system(size: size * 0.5, weight: .bold))
                        .foregroundStyle(BrandColors.background)
                }
        }
    }
}
