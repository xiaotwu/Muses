import SwiftUI

/// Skeleton placeholder primitives (never mask slow requests with a centered spinner).
///
/// Lightweight shimmer/tinted blocks shown while a section is `loading` with no cached content. Honors Reduce Motion:
/// `animated` degrades to a static tinted block under Reduce Motion.
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var cornerRadius: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(BrandColors.surface)
            .frame(width: width, height: height)
            .overlay(
                LinearGradient(
                    colors: [
                        BrandColors.textPrimary.opacity(0.0),
                        BrandColors.textPrimary.opacity(0.08),
                        BrandColors.textPrimary.opacity(0.0)
                    ],
                    startPoint: .leading, endPoint: .trailing)
                    .mask(RoundedRectangle(cornerRadius: cornerRadius))
            )
            .opacity(reduceMotion ? 1.0 : 0.85)
            .accessibilityHidden(true)
    }
}

/// Card skeleton (square or 16:9).
struct SkeletonCard: View {
    enum Aspect { case square, wide169 }
    var size: CGFloat = 160
    var aspect: Aspect = .square
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SkeletonBlock(width: size,
                          height: aspect == .square ? size : size * 9.0 / 16.0)
            SkeletonBlock(width: size * 0.7, height: 10)
            SkeletonBlock(width: size * 0.45, height: 8)
        }
        .frame(width: size)
    }
}

/// Row skeleton (matched to song-row rhythm).
struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 10) {
            SkeletonBlock(width: 44, height: 44, cornerRadius: 4)
            VStack(alignment: .leading, spacing: 4) {
                SkeletonBlock(width: 120, height: 10)
                SkeletonBlock(width: 80, height: 8)
            }
            Spacer(minLength: 0)
        }
    }
}