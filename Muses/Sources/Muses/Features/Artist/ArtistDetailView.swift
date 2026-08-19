import SwiftUI
import AppKit
import SwiftData

struct ArtistDetailView: View {
    let artist: Artist
    @Binding var selection: Artist?
    @Environment(LibraryService.self) private var library
    @Environment(PlaybackService.self) private var playback
    @Query(sort: \Playlist.name) private var allPlaylists: [Playlist]
    @Binding var selectedAlbum: Album?
    @State private var gradient: [Color] = [BrandColors.background, BrandColors.surface]
    @State private var gradientTask: Task<Void, Never>?
    /// 批量已喜欢 id 集合,避免每行单独 fetch。
    @State private var likedSet: Set<UUID> = []
    @State private var selectedTrackID: UUID?

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: 4)
    }

    /// 从 Artist 关系派生的专辑(按标题排序),在 fresh context 中 re-fetch 以获得有效对象。
    private var albums: [Album] {
        library.albums(byArtist: artist)
    }
    /// 从 Artist 关系派生的曲目(按专辑+曲目号排序)。
    private var tracks: [Track] {
        library.tracks(byArtist: artist)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: gradient, startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView {
                let _ = library.pinRevision
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if !albums.isEmpty {
                        albumSection
                    }
                    if !tracks.isEmpty {
                        trackSection
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { selection = nil } label: { Image(systemName: "chevron.backward") }
            }
        }
        .onAppear { extractGradient(); refreshLikedSet() }
        .onDisappear { gradientTask?.cancel(); gradientTask = nil }
        .onChange(of: library.likedRevision) { _, _ in refreshLikedSet() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            ArtworkView(
                source: ArtworkSource.localHash(artist.artworkHash),
                glyphSize: 48,
                clipCircle: true,
                targetSize: 180
            )
            VStack(alignment: .leading, spacing: 8) {
                Text(artist.name).font(.largeTitle).fontWeight(.bold)
                    .foregroundStyle(BrandColors.textPrimary)
                if let genre = artist.primaryGenre {
                    Text(genre).font(.caption).foregroundStyle(BrandColors.cyan)
                        .glow(BrandColors.cyan, radius: 2)
                }
                Text("\(albums.count) \(tr("albums", "张专辑")) · \(tracks.count) \(tr("songs", "首歌曲"))")
                    .font(.title3).foregroundStyle(BrandColors.textSecondary)
                Button { playAll() } label: {
                    Label(tr("Play", "播放"), systemImage: "play.fill").padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColors.magenta)
            }
            Spacer()
        }
    }

    private var albumSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Albums", "专辑")).font(.headline).foregroundStyle(BrandColors.textPrimary)
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(albums, id: \.id) { album in
                    AlbumObjectView(
                        title: album.title,
                        subtitle: album.albumArtist,
                        artwork: ArtworkSource.localHash(album.artworkHash),
                        size: MusicObjectMetrics.albumGrid,
                        role: .browse,
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

    private var trackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Songs", "歌曲")).font(.headline).foregroundStyle(BrandColors.textPrimary)
            VStack(spacing: 0) {
                ForEach(tracks, id: \.id) { track in
                    SongObjectView(
                        title: track.title,
                        artist: track.artist,
                        durationLabel: songDuration(track.durationSeconds),
                        artwork: ArtworkSource.localHash(track.localArtworkHash ?? track.album?.artworkHash),
                        isSelected: selectedTrackID == track.id,
                        isLossless: track.isLossless,
                        isLiked: likedSet.contains(track.id),
                        onToggleLike: { library.toggleLike(track) },
                        onSelect: { selectedTrackID = track.id; play(track) },
                        onPlay: { play(track) }
                    )
                    .trackContextMenu(snapshot: TrackSnapshot(from: track),
                                      track: track,
                                      playlists: allPlaylists,
                                      onPlay: { play(track) })
                }
            }
        }
    }

    private func play(_ track: Track) {
        let snaps = tracks.map { TrackSnapshot(from: $0) }
        guard let snap = snaps.first(where: { $0.id == track.id }) else { return }
        playback.playTrack(snap, context: snaps, from: .artist)
    }

    private func refreshLikedSet() {
        likedSet = library.likedIDs(for: tracks.map(\.id))
    }

    private func playAll() {
        guard let first = tracks.first else { return }
        play(first)
    }

    private func playAlbum(_ album: Album) {
        let snaps = library.tracks(in: album).map { TrackSnapshot(from: $0) }
        guard let first = snaps.first else { return }
        playback.playTrack(first, context: snaps, from: .album)
    }

    private func songDuration(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    private func extractGradient() {
        gradientTask?.cancel()
        guard let album = albums.first else { return }
        let source = ArtworkSource.localHash(album.artworkHash)
        guard case .localFile = source else { return }
        let expectedArtistID = artist.id
        gradientTask = Task { @MainActor in
            let img = await Task.detached(priority: .userInitiated) {
                source.loadNSImage()
            }.value
            guard !Task.isCancelled, artist.id == expectedArtistID, let img else { return }
            let colors = AlbumArtworkExtractor.dominantColors(img, count: 3)
            guard !Task.isCancelled else { return }
            gradient = colors.map { Color(nsColor: $0) } + [BrandColors.background]
        }
    }
}