import SwiftUI

struct SongObjectView: View {
    let title: String
    let artist: String
    var albumTitle: String? = nil
    var durationLabel: String? = nil
    var indexLabel: String? = nil
    let artwork: ArtworkSource
    var isSelected: Bool = false
    var isNowPlaying: Bool = false
    /// Track identity for `NowPlayingMark`. The only object-level playback read.
    var nowPlayingID: UUID? = nil
    var showsHoverPlay: Bool = false
    var showsPlayButton: Bool = false
    /// When true, double-click calls `onPlay` on this same view (Songs list). Default false.
    var playsOnDoubleClick: Bool = false
    var isLossless: Bool = false
    var showLocalBadge: Bool = false
    var isLiked: Bool? = nil
    var onToggleLike: (() -> Void)? = nil
    var onSelect: () -> Void
    var onPlay: () -> Void
    var onRemove: (() -> Void)? = nil
    var onQueue: (() -> Void)? = nil
    var onInbox: (() -> Void)? = nil
    var onOverflow: (() -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            if let indexLabel {
                Text(indexLabel)
                    .foregroundStyle(BrandColors.textSecondary)
                    .frame(width: 28, alignment: .trailing)
            }

            ArtworkView(
                source: artwork,
                cornerRadius: 4,
                glyphSize: 16,
                targetSize: MusicObjectMetrics.songArtMin
            )
            .overlay { hoverPlayOverlay }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    nowPlayingBadge
                    Text(title)
                        .foregroundStyle(BrandColors.textPrimary)
                        .lineLimit(1)
                    if isLossless {
                        Text(tr("Hi-Res", "Hi-Res"))
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(BrandColors.green.opacity(0.2))
                            .foregroundStyle(BrandColors.green)
                            .cornerRadius(4)
                    }
                    if showLocalBadge {
                        Text(tr("Local", "本地"))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(BrandColors.green.opacity(0.2))
                            .foregroundStyle(BrandColors.green)
                            .cornerRadius(4)
                    }
                }
                Text(artist)
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
                    .lineLimit(1)
            }

            if let albumTitle {
                Text(albumTitle)
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
                    .lineLimit(1)
                    .frame(width: 160, alignment: .leading)
            }

            Spacer(minLength: 0)

            if let isLiked {
                Button(action: { onToggleLike?() }) {
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .font(.caption)
                }
                .foregroundStyle(isLiked ? BrandColors.magenta : BrandColors.textSecondary)
                .buttonStyle(.plain)
                .help(isLiked ? tr("Unlike", "取消收藏") : tr("Like", "收藏"))
                .accessibilityLabel(isLiked ? tr("Unlike", "取消收藏") : tr("Like", "收藏"))
            }

            if let durationLabel {
                Text(durationLabel)
                    .foregroundStyle(BrandColors.textSecondary)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }

            if showsPlayButton {
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .foregroundStyle(BrandColors.magenta)
                }
                .buttonStyle(.plain)
                .help(tr("Play", "播放"))
                .accessibilityLabel(tr("Play", "播放"))
            }

            if let onQueue {
                Button(action: onQueue) {
                    Image(systemName: "text.badge.plus")
                        .foregroundStyle(BrandColors.textSecondary)
                }
                .buttonStyle(.plain)
                .help(tr("Add to Queue", "加入队列"))
                .accessibilityLabel(tr("Add to Queue", "加入队列"))
            }

            if let onInbox {
                Button(action: onInbox) {
                    Image(systemName: "tray.and.arrow.down")
                        .foregroundStyle(BrandColors.textSecondary)
                }
                .buttonStyle(.plain)
                .help(tr("Save to Inbox", "保存到收件箱"))
                .accessibilityLabel(tr("Save to Inbox", "保存到收件箱"))
            }

            if let onOverflow {
                Button(action: onOverflow) {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(BrandColors.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("More", "更多"))
            }

            if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(BrandColors.textSecondary)
                .help(tr("Remove", "移除"))
                .accessibilityLabel(tr("Remove", "移除"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? BrandColors.surface : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .modifier(SongRowTapModifier(
            onSelect: onSelect,
            onDoubleClick: playsOnDoubleClick ? onPlay : nil
        ))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) — \(artist)")
    }

    /// Songs list: hover Play on the 44pt art when hovered or selected. Never lifts.
    @ViewBuilder
    private var hoverPlayOverlay: some View {
        if showsHoverPlay {
            HoverPlayButton(onPlay: onPlay)
                .opacity((hovering || isSelected) ? 1 : 0)
                .allowsHitTesting(hovering || isSelected)
        }
    }

    @ViewBuilder
    private var nowPlayingBadge: some View {
        if let nowPlayingID {
            NowPlayingMark(itemID: nowPlayingID)
                .font(.caption)
        } else if isNowPlaying {
            Image(systemName: "speaker.wave.2")
                .font(.caption)
                .foregroundStyle(BrandColors.textPrimary)
                .accessibilityHidden(true)
        }
    }
}

/// Single-tap and optional double-tap on the same view. A parent `count: 2`
/// loses to this view's exclusive single-tap on macOS.
private struct SongRowTapModifier: ViewModifier {
    let onSelect: () -> Void
    var onDoubleClick: (() -> Void)?

    func body(content: Content) -> some View {
        if let onDoubleClick {
            content
                .onTapGesture(count: 2, perform: onDoubleClick)
                .onTapGesture(count: 1, perform: onSelect)
        } else {
            content.onTapGesture(perform: onSelect)
        }
    }
}
