import SwiftUI

/// "Up Next" preview at the bottom of the Now Playing right column: up to 5 items, tapping jumps playback,
/// with a "show full queue" button at the end (opens QueueDrawerView).
struct UpNextPreview: View {
    @Environment(PlaybackService.self) private var playback
    let onShowQueue: () -> Void

    private var items: [QueueItem] { Array(playback.queue.upNext.prefix(5)) }

    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(tr("Up Next", "即将播放"))
                        .font(.headline)
                        .foregroundStyle(BrandColors.textPrimary)
                    Spacer()
                    Button { onShowQueue() } label: {
                        Image(systemName: "list.bullet")
                            .foregroundStyle(BrandColors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help(tr("Show Full Queue", "显示完整队列"))
                }

                ForEach(items, id: \.id) { item in
                    Button {
                        jump(to: item.id)
                    } label: {
                        HStack(spacing: 10) {
                            ArtworkView(source: ArtworkSource.resolve(for: item.track),
                                        cornerRadius: 4, glyphSize: 14, targetSize: 36)
                                .frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.track.title).font(.callout).lineLimit(1)
                                    .foregroundStyle(BrandColors.textPrimary)
                                Text(item.track.artist).font(.caption).lineLimit(1)
                                    .foregroundStyle(BrandColors.textSecondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Moves the given up-next item to the head of the queue and triggers next() to load playback.
    private func jump(to id: UUID) {
        guard let idx = playback.queue.upNext.firstIndex(where: { $0.id == id }) else { return }
        if idx != 0 { playback.queue.moveUpNext(from: idx, to: 0) }
        playback.next()
    }
}