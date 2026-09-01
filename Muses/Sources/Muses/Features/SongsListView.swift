import SwiftData
import SwiftUI

struct MetadataProjectionErrorBanner: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(tr("Some library metadata is unavailable", "部分资料库元数据不可用"))
                .font(.callout.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
                .lineLimit(3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            BrandColors.surface.opacity(0.7),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }
}

struct SongsListView: View {
    @Environment(LibraryService.self) private var library
    @Environment(PlaybackService.self) private var playback
    @Query(sort: \Playlist.name) private var allPlaylists: [Playlist]

    var body: some View {
        let _ = library.likedRevision
        let _ = library.metadataRevision
        let rows = CollectionTrackRow.songs(from: library.allTracks())
        let snapshots = rows.map(\.snapshot)

        CollectionPage(
            title: tr("Songs", "歌曲"),
            subtitle: tr(
                "\(rows.count) songs • Title A–Z",
                "\(rows.count) 首歌曲 • 标题 A–Z"
            ),
            rows: rows,
            defaultSort: .titleAZ,
            currentTrack: playback.state.track,
            playlists: allPlaylists,
            emptyIcon: "music.note",
            emptyTitle: tr("No songs in library", "资料库中没有歌曲"),
            emptySubtitle: tr(
                "Open Search (⌘F) and paste a YouTube link",
                "打开搜索(⌘F)并粘贴 YouTube 链接"
            ),
            onPlay: { row in
                playback.playTrack(row.snapshot, context: snapshots, from: .songs)
            }
        ) {
            HStack(spacing: 8) {
                ChromeIconButton(
                    systemName: "play.fill",
                    help: tr("Play All", "播放全部"),
                    accessibility: tr("Play All", "播放全部")
                ) {
                    guard let first = snapshots.first else { return }
                    playback.playTrack(first, context: snapshots, from: .songs)
                }
                ChromeIconButton(
                    systemName: "shuffle",
                    help: tr("Shuffle", "随机播放"),
                    accessibility: tr("Shuffle", "随机播放")
                ) {
                    let shuffled = snapshots.shuffled()
                    guard let first = shuffled.first else { return }
                    playback.playTrack(first, context: shuffled, from: .songs)
                }
            }
        }
    }
}
