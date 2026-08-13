import SwiftUI

/// 钉选页:展示已钉选的专辑和歌单(Task 3 将完整实现)。
struct PinsView: View {
    @Binding var selection: SidebarSection
    @Binding var selectedAlbum: Album?
    @Binding var selectedPlaylist: Playlist?
    @Environment(LibraryService.self) private var library
    @Environment(PlaylistService.self) private var playlistService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
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
    }

    private func pinnedAlbumsSection(_ albums: [Album]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Pinned Albums", "钉选专辑"))
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(BrandColors.textPrimary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 5),
                      spacing: 20) {
                ForEach(albums, id: \.id) { album in
                    AlbumCard(album: album)
                        .onTapGesture { selectedAlbum = album }
                }
            }
        }
    }

    private func pinnedPlaylistsSection(_ playlists: [Playlist]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Pinned Playlists", "钉选歌单"))
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(BrandColors.textPrimary)
            LazyVStack(spacing: 8) {
                ForEach(playlists, id: \.id) { playlist in
                    PlaylistCard(playlist: playlist,
                                 onTap: { selectedPlaylist = playlist },
                                 onDelete: { })
                }
            }
        }
    }
}