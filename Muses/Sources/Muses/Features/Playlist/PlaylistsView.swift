import SwiftUI
import SwiftData

/// 歌单列表页:展示所有歌单 + 新建/删除。
struct PlaylistsView: View {
    @Environment(PlaylistService.self) private var playlistService
    @Environment(PlaybackService.self) private var playback
    @Binding var selectedPlaylist: Playlist?
    @State private var playlists: [Playlist] = []
    @State private var showCreateSheet = false
    @State private var newPlaylistName = ""

    var body: some View {
        ScrollView {
            if playlists.isEmpty {
                EmptyStateView(icon: "music.note.list", title: tr("No playlists", "暂无歌单"),
                               subtitle: tr("Tap + at top right to create a playlist", "点击右上角 + 创建歌单"))
                    .padding(16)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 5),
                          spacing: 20) {
                    ForEach(playlists, id: \.id) { playlist in
                        AlbumObjectView(
                            title: playlist.name,
                            subtitle: "\(playlist.items?.count ?? 0) \(tr("songs", "首"))",
                            artwork: playlistArtwork(playlist),
                            size: MusicObjectMetrics.albumGrid,
                            role: .browse,
                            onSelect: { selectedPlaylist = playlist },
                            onPlay: { playPlaylist(playlist) }
                        )
                        .contextMenu {
                            Button(playlist.pinned ? tr("Unpin", "取消钉选") : tr("Pin", "钉选")) {
                                playlistService.togglePin(playlist)
                            }
                            Button(tr("Delete Playlist", "删除歌单"), role: .destructive) {
                                deletePlaylist(playlist)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(BrandColors.background)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { showCreateSheet = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            VStack(spacing: 16) {
                Text(tr("New Playlist", "新建歌单")).font(.headline)
                TextField(tr("Playlist name", "歌单名称"), text: $newPlaylistName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(tr("Cancel", "取消")) { showCreateSheet = false; newPlaylistName = "" }
                    Button(tr("Create", "创建")) {
                        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty {
                            playlistService.create(name: name)
                            refresh()
                        }
                        showCreateSheet = false
                        newPlaylistName = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandColors.magenta)
                    .disabled(newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 320)
            .background(.ultraThinMaterial)
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        playlists = playlistService.fetchAll()
    }

    private func deletePlaylist(_ playlist: Playlist) {
        playlistService.delete(playlist)
        refresh()
    }

    private func playPlaylist(_ playlist: Playlist) {
        let snaps = (playlist.items ?? []).sorted { $0.order < $1.order }
            .compactMap { $0.track }
            .map { TrackSnapshot(from: $0) }
        guard let first = snaps.first else { return }
        playback.playTrack(first, context: snaps, from: .playlist)
    }

    private func playlistArtwork(_ playlist: Playlist) -> ArtworkSource {
        guard let track = (playlist.items ?? []).sorted(by: { $0.order < $1.order }).first?.track else {
            return .placeholder
        }
        return ArtworkSource.resolve(for: TrackSnapshot(from: track))
    }
}