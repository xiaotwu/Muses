import SwiftUI

/// Phase D4 — 骨架占位原子(§15:不使用居中 spinner 掩盖慢请求)。
///
/// 轻量 shimmer/淡色块,用于 section `loading` 且无缓存时。尊重 Reduce Motion:
/// `animated` 在 Reduce Motion 下退化为静态淡色块。
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

/// 卡片骨架(方形/16:9)。
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

/// 行骨架(配合歌曲行节奏)。
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