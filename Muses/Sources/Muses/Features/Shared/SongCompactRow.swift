import SwiftUI
import AppKit

/// Phase D4 — 紧凑歌曲行原语:封面 + 标题 + 艺术家 + "…",用于 2–4 列歌曲网格。
///
/// 统一本地曲目(artworkHash)与 YouTube(缩略图/封面 URL)的行呈现。点击经 `onPlay`。
struct SongCompactRow: View {
    let title: String
    let artist: String
    var artworkPath: URL? = nil
    var remoteURL: URL? = nil
    var durationLabel: String? = nil
    var onPlay: (() -> Void)? = nil
    var onOverflow: (() -> Void)? = nil

    private let rowHeight: CGFloat = 44

    var body: some View {
        HStack(spacing: 10) {
            artwork
                .frame(width: rowHeight, height: rowHeight)
                .clipped()
                .cornerRadius(4)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(BrandColors.textPrimary)
                Text(artist)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(BrandColors.textSecondary)
            }
            Spacer(minLength: 0)
            if let durationLabel {
                Text(durationLabel)
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
                    .monospacedDigit()
            }
            if let onOverflow {
                Button(action: onOverflow) {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(BrandColors.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("More", "更多"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onPlay?() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) — \(artist)")
    }

    @ViewBuilder
    private var artwork: some View {
        if let path = artworkPath,
           let img = NSImage(contentsOf: path) {
            Image(nsImage: img).resizable().scaledToFill()
        } else if let remoteURL {
            CachedAsyncImage(url: remoteURL,
                             content: { $0.resizable().scaledToFill() },
                             placeholder: { placeholder })
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Rectangle().fill(BrandColors.surface)
            .overlay(Image(systemName: "music.note").font(.caption)
                .foregroundStyle(BrandColors.textSecondary.opacity(0.5)))
    }
}