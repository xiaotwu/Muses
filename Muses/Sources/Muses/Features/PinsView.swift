import SwiftUI

/// 钉选页:展示已钉选的专辑和歌单(Task 3 将完整实现)。
struct PinsView: View {
    @Binding var selection: SidebarSection
    @Binding var selectedAlbum: Album?
    @Binding var selectedPlaylist: Playlist?
    @Environment(LibraryService.self) private var library
    @Environment(PlaylistService.self) private var playlistService
    @Environment(PlaybackService.self) private var playback
    @State private var playingAlbumID: UUID?
    @State private var playingArtistID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                let _ = library.pinRevision
                let pinnedAlbums = library.pinnedAlbums()
                let pinnedPlaylists = playlistService.pinnedPlaylists()

                if pinnedAlbums.isEmpty && pinnedPlaylists.isEmpty {
                    EmptyStateView(
                        icon: "pin",
                        title: tr("No Pins", "暂无钉选"),
                        subtitle: tr("Right-click albums or playlists to pin them",
                                     "右键点击专辑或歌单进行钉选")
                    )
                    .padding(.top, 60)
                } else {
                    if !pinnedAlbums.isEmpty {
                        pinnedAlbumsSection(pinnedAlbums)
                    }
                    if !pinnedPlaylists.isEmpty {
                        pinnedPlaylistsSection(pinnedPlaylists)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle(tr("Pins", "钉选"))
        .background(BrandColors.background)
        .onAppear { refreshPlayingCollection() }
        .onChange(of: playback.state.track?.id) { _, _ in refreshPlayingCollection() }
    }

    private func pinnedAlbumsSection(_ albums: [Album]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Pinned Albums", "钉选专辑"))
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(BrandColors.textPrimary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 5),
                      spacing: 20) {
                ForEach(albums, id: \.id) { album in
                    AlbumObjectView(
                        title: album.title,
                        subtitle: album.albumArtist,
                        artwork: ArtworkSource.localHash(album.artworkHash),
                        size: MusicObjectMetrics.albumGrid,
                        role: .browse,
                        isNowPlaying: album.id == playingAlbumID,
                        showsHoverPlay: true,
                        onSelect: { selectedAlbum = album },
                        onPlay: { playAlbum(album) }
                    )
                    .contextMenu {
                        Button(library.isPinned(album) ? tr("Unpin", "取消钉选") : tr("Pin", "钉选")) {
                            library.togglePin(album)
                        }
                    }
                }
            }
        }
    }

    private func pinnedPlaylistsSection(_ playlists: [Playlist]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Pinned Playlists", "钉选歌单"))
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(BrandColors.textPrimary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 5),
                      spacing: 20) {
                ForEach(playlists, id: \.id) { playlist in
                    AlbumObjectView(
                        title: playlist.name,
                        subtitle: "\(playlist.items?.count ?? 0) \(tr("songs", "首"))",
                        artwork: playlistArtwork(playlist),
                        size: MusicObjectMetrics.albumGrid,
                        role: .browse,
                        showsHoverPlay: true,
                        onSelect: { selectedPlaylist = playlist },
                        onPlay: { playPlaylist(playlist) }
                    )
                    .contextMenu {
                        Button(playlist.pinned ? tr("Unpin", "取消钉选") : tr("Pin", "钉选")) {
                            playlistService.togglePin(playlist)
                        }
                    }
                }
            }
        }
    }

    private func refreshPlayingCollection() {
        let id = playback.state.track?.id
        playingAlbumID = id.flatMap { library.track(by: $0)?.album?.id }
        playingArtistID = id.flatMap { library.track(by: $0)?.artistRef?.id }
    }

    private func playAlbum(_ album: Album) {
        let snaps = library.tracks(in: album).map { TrackSnapshot(from: $0) }
        guard let first = snaps.first else { return }
        playback.playTrack(first, context: snaps, from: .album)
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