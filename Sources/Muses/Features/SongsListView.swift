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

enum LibraryCollectionFilter: String, CaseIterable {
    case all, liked, musicVideos

    var title: String {
        switch self {
        case .all: tr("Songs", "歌曲")
        case .liked: tr("Favorites", "收藏")
        case .musicVideos: tr("Music Videos", "音乐视频")
        }
    }

    func includes(_ track: Track) -> Bool {
        switch self {
        case .all: true
        case .liked: track.liked
        case .musicVideos: track.mediaKind == .musicVideo
        }
    }
}

struct SongsListView: View {
    var filter: LibraryCollectionFilter = .all
    @Environment(LibraryService.self) private var library
    @Environment(PlaybackService.self) private var playback
    @Query(sort: \Playlist.name) private var allPlaylists: [Playlist]

    var body: some View {
        let _ = library.likedRevision
        let _ = library.metadataRevision
        let rows = CollectionTrackRow.songs(from: library.allTracks().filter { filter.includes($0) })
        let snapshots = rows.map(\.snapshot)

        CollectionPage(
            title: filter.title,
            subtitle: tr(
                "\(rows.count) songs • Title A–Z",
                "\(rows.count) 首歌曲 • 标题 A–Z", zhHant: "\(rows.count) 首歌曲 • 標題 A–Z"
            ),
            rows: rows,
            defaultSort: .titleAZ,
            currentTrack: playback.state.track,
            playlists: allPlaylists,
            emptyIcon: "music.note",
            emptyTitle: filter == .liked ? tr("No favorites yet", "还没有收藏") : filter == .musicVideos ? tr("No music videos yet", "还没有音乐视频") : tr("No songs in library", "资料库中没有歌曲"),
            emptySubtitle: filter == .liked
                ? tr("Like a song to find it here. Favorites are saved in Muses.", "收藏歌曲后会显示在这里。收藏保存在 Muses 中。")
                : tr("Search YouTube and paste a link to start your library.", "搜索 YouTube 并粘贴链接，开始建立资料库。"),
            emptyActionTitle: tr("Open Search", "打开搜索"),
            emptyAction: {
                NotificationCenter.default.post(name: .musesFocusSearch, object: nil)
            },
            onPlay: { row in
                playback.playTrack(row.snapshot, context: snapshots, from: .songs)
            }
        ) {
            if !rows.isEmpty {
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
}
