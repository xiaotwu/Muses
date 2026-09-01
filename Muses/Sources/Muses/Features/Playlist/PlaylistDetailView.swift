import SwiftUI
import SwiftData

/// User-playlist detail using the shared collection composition. Membership and
/// playback always follow PlaylistItem.order; table sorting is visual only.
struct PlaylistDetailView: View {
    let playlist: Playlist
    @Binding var selectedPlaylist: Playlist?
    @Environment(PlaylistService.self) private var playlistService
    @Environment(PlaybackService.self) private var playback
    @Query(sort: \Playlist.name) private var allPlaylists: [Playlist]
    @State private var rows: [CollectionTrackRow] = []

    private var sortedItems: [PlaylistItem] {
        (playlist.items ?? []).sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private var snapshots: [TrackSnapshot] { rows.map(\.snapshot) }

    var body: some View {
        CollectionPage(
            title: playlist.name,
            subtitle: tr(
                "\(rows.count) songs • Playlist Order",
                "\(rows.count) 首歌曲 • 歌单顺序"
            ),
            rows: rows,
            defaultSort: .playlistOrder,
            currentTrack: playback.state.track,
            playlists: allPlaylists,
            emptyTitle: tr("Playlist is empty", "歌单为空"),
            emptySubtitle: tr(
                "Add YouTube songs from a song's context menu",
                "通过歌曲的右键菜单添加 YouTube 歌曲"
            ),
            onPlay: { row in
                playback.playTrack(row.snapshot, context: snapshots, from: .playlist)
            },
            onRemove: { row in
                guard let item = sortedItems.first(where: {
                    $0.track?.id == row.id
                        || ($0.track?.youTubeId != nil
                            && $0.track?.youTubeId == row.snapshot.youTubeId)
                }) else { return }
                playlistService.removeItem(item)
            }
        ) {
            HStack(spacing: 8) {
                ChromeIconButton(
                    systemName: "chevron.backward",
                    help: tr("Back", "返回"),
                    accessibility: tr("Back", "返回")
                ) { selectedPlaylist = nil }
                ChromeIconButton(
                    systemName: "play.fill",
                    help: tr("Play All", "播放全部"),
                    accessibility: tr("Play All", "播放全部"),
                    action: playAll
                )
                ChromeIconButton(
                    systemName: "shuffle",
                    help: tr("Shuffle", "随机播放"),
                    accessibility: tr("Shuffle", "随机播放"),
                    action: shuffleAll
                )
            }
        }
        .onAppear(perform: reloadRows)
        .onReceive(NotificationCenter.default.publisher(for: .musesPlaylistsChanged)) { _ in
            reloadRows()
        }
    }

    private func reloadRows() {
        rows = CollectionTrackRow.playlist(from: sortedItems)
    }

    private func playAll() {
        guard let first = snapshots.first else { return }
        playback.playTrack(first, context: snapshots, from: .playlist)
    }

    private func shuffleAll() {
        let shuffled = snapshots.shuffled()
        guard let first = shuffled.first else { return }
        playback.playTrack(first, context: shuffled, from: .playlist)
    }
}
