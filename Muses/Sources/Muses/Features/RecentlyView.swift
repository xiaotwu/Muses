import SwiftUI

/// 最近添加页:按 addedAt 降序展示专辑。
struct RecentlyView: View {
    @Binding var selection: SidebarSection
    @Binding var selectedAlbum: Album?
    @Environment(LibraryService.self) private var library
    @Environment(PlaybackService.self) private var playback
    @State private var playingAlbumID: UUID?
    @State private var playingArtistID: UUID?

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: 4)
    }

    var body: some View {
        ScrollView {
            let _ = library.pinRevision
            let albums = library.allAlbums().sorted { a, b in
                // 按专辑中最新曲目的 addedAt 排序(无曲目则用最早)
                let aDate = a.tracks.map(\.addedAt).max() ?? .distantPast
                let bDate = b.tracks.map(\.addedAt).max() ?? .distantPast
                return aDate > bDate
            }
            if albums.isEmpty {
                EmptyStateView(
                    icon: "clock",
                    title: tr("No Albums", "暂无专辑"),
                    subtitle: tr("Import music to see recently added albums",
                                 "导入音乐后这里会显示最近添加的专辑")
                )
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(albums.prefix(50), id: \.id) { album in
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
                .padding(24)
            }
        }
        .navigationTitle(tr("Recently", "最近"))
        .background(BrandColors.background)
        .onAppear { refreshPlayingCollection() }
        .onChange(of: playback.state.track?.id) { _, _ in refreshPlayingCollection() }
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
}