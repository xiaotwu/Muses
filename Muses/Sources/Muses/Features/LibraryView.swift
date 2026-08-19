import SwiftUI
import SwiftData

struct LibraryView: View {
    @Binding var selection: SidebarSection
    @Binding var selectedAlbum: Album?
    @Binding var selectedBrowsableAlbum: BrowsableAlbum?
    @Environment(LibraryService.self) private var library
    @Environment(PlaybackService.self) private var playback
    @Environment(MetadataEnrichmentService.self) private var enrichment
    @State private var projection = BrowseProjection.empty

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: 5)
    }

    var body: some View {
        ScrollView {
            let progress = library.scanProgress
            if progress.total > 0, progress.scanned < progress.total {
                ProgressView(value: Double(progress.scanned), total: Double(progress.total))
                    .padding()
            }
            let _ = library.pinRevision
            let albums = library.allAlbums()
            let derivedAlbums = projection.albums.filter { !$0.isLocal }
            if albums.isEmpty && derivedAlbums.isEmpty && progress.total == 0 {
                EmptyStateView(icon: "square.stack", title: tr("Library is empty", "资料库为空"),
                               subtitle: tr("Open Search (⌘F) and tap + to import a music folder, or drag files into the window", "打开搜索(⌘F)点击 + 导入音乐文件夹,或拖拽文件到窗口"))
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
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
                .padding(20)

                // P3 — YouTube-derived 专辑(MusicBrainz 确认 ≥0.70 后 surfaced,带 YT 标识)。
                if !derivedAlbums.isEmpty {
                    HStack {
                        Text(tr("YouTube", "YouTube")).font(.headline)
                            .foregroundStyle(BrandColors.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(derivedAlbums) { browsable in
                            BrowsableAlbumCard(
                                browsable: browsable,
                                onSelect: { selectedBrowsableAlbum = browsable },
                                onPlay: { playBrowsable(browsable) }
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle(tr("Albums", "专辑"))
        .background(BrandColors.background)
        .task { await loadProjection() }
        .onChange(of: enrichment.enrichmentRevision) { _, _ in
            Task { await loadProjection() }
        }
    }

    private func loadProjection() async {
        await enrichment.refreshCandidates()
        projection = await enrichment.projection()
        await enrichment.enrichDerived()
        projection = await enrichment.projection()
    }

    private func playAlbum(_ album: Album) {
        let snaps = library.tracks(in: album).map { TrackSnapshot(from: $0) }
        guard let first = snaps.first else { return }
        playback.playTrack(first, context: snaps, from: .album)
    }

    private func playBrowsable(_ browsable: BrowsableAlbum) {
        guard let first = browsable.trackSnapshots.first else { return }
        playback.playTrack(first, context: browsable.trackSnapshots, from: .album)
    }
}

struct SongsListView: View {
    @Environment(LibraryService.self) private var library
    @Environment(PlaybackService.self) private var playback
    @Query(sort: \Playlist.name) private var allPlaylists: [Playlist]
    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var sortKey: SortKey = .title
    @State private var selectedSongID: UUID?
    /// 批量已喜欢 id 集合:在 `.onAppear` / `likedRevision` 变化时一次性 fetch,
    /// 避免每行各自新建 ModelContext 查询。
    @State private var likedSet: Set<UUID> = []

    private enum SortKey: String, CaseIterable, Identifiable {
        case title, artist, album, dateAdded
        var id: String { rawValue }
        var label: String {
            switch self {
            case .title: tr("Title", "标题"); case .artist: tr("Artist", "艺术家"); case .album: tr("Album", "专辑"); case .dateAdded: tr("Date Added", "添加时间")
            }
        }
    }

    var body: some View {
        let _ = library.likedRevision
        let _ = library.metadataRevision
        let tracks = sortedTracks(library.allTracks(search: debouncedSearch.isEmpty ? nil : debouncedSearch))
        Group {
            if tracks.isEmpty {
                EmptyStateView(
                    icon: "music.note",
                    title: searchText.isEmpty ? tr("No songs in library", "资料库中没有歌曲") : tr("No search results", "无搜索结果"),
                    subtitle: searchText.isEmpty ? tr("Open Search (⌘F) and tap + to import a music folder", "打开搜索(⌘F)点击 + 导入音乐文件夹") : nil)
            } else {
                List(tracks, id: \.id, selection: $selectedSongID) { track in
                    SongObjectView(
                        title: track.title,
                        artist: track.artist,
                        albumTitle: track.albumTitle ?? "",
                        durationLabel: songDuration(track.durationSeconds),
                        artwork: ArtworkSource.localHash(track.localArtworkHash ?? track.album?.artworkHash),
                        isSelected: selectedSongID == track.id,
                        isLossless: track.isLossless,
                        isLiked: likedSet.contains(track.id),
                        onToggleLike: { library.toggleLike(track) },
                        onSelect: { selectedSongID = track.id },
                        onPlay: { play(track, from: tracks) }
                    )
                    .onTapGesture(count: 2) { play(track, from: tracks) }
                    .trackContextMenu(snapshot: TrackSnapshot(from: track),
                                      track: track,
                                      playlists: allPlaylists,
                                      onPlay: { play(track, from: tracks) })
                    .tag(track.id)
                }
                .onKeyPress(.return) {
                    guard let id = selectedSongID,
                          let track = tracks.first(where: { $0.id == id }) else { return .ignored }
                    play(track, from: tracks)
                    return .handled
                }
            }
        }
        .navigationTitle(tr("Songs", "歌曲"))
        .searchable(text: $searchText, prompt: tr("Search songs, artists, albums", "搜索歌曲、艺术家、专辑"))
        .onChange(of: searchText) { _, newValue in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                debouncedSearch = newValue
            }
        }
        .onAppear { refreshLikedSet() }
        .onChange(of: library.likedRevision) { _, _ in refreshLikedSet() }
        .onChange(of: debouncedSearch) { _, _ in refreshLikedSet() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker(tr("Sort", "排序"), selection: $sortKey) {
                    ForEach(SortKey.allCases) { key in Text(key.label).tag(key) }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private func sortedTracks(_ tracks: [Track]) -> [Track] {
        switch sortKey {
        case .title:     tracks.sorted { $0.title < $1.title }
        case .artist:    tracks.sorted { $0.artist < $1.artist }
        case .album:     tracks.sorted { ($0.albumTitle ?? "") < ($1.albumTitle ?? "") }
        case .dateAdded: tracks.sorted { $0.addedAt > $1.addedAt }
        }
    }

    private func play(_ track: Track, from tracks: [Track]) {
        let snaps = tracks.map { TrackSnapshot(from: $0) }
        guard let snap = snaps.first(where: { $0.id == track.id }) else { return }
        playback.playTrack(snap, context: snaps, from: .songs)
    }

    /// 用当前可见曲目的 id 批量查询已喜欢集合,行内查询降为 O(1) `contains`。
    private func refreshLikedSet() {
        let tracks = sortedTracks(library.allTracks(search: debouncedSearch.isEmpty ? nil : debouncedSearch))
        likedSet = library.likedIDs(for: tracks.map(\.id))
    }
}

struct LikedView: View {
    @Environment(LibraryService.self) private var library
    @Environment(PlaybackService.self) private var playback
    @Query(filter: #Predicate<Track> { $0.liked == true },
           sort: \Track.addedAt, order: .reverse)
    private var tracks: [Track]
    @Query(sort: \Playlist.name) private var allPlaylists: [Playlist]
    @State private var selectedSongID: UUID?
    var body: some View {
        if tracks.isEmpty {
            EmptyStateView(icon: "heart", title: tr("No liked songs yet", "还没有收藏的歌曲"),
                           subtitle: tr("Tap ❤️ next to a song to like it", "点击歌曲旁的 ❤️ 收藏"))
                .navigationTitle(tr("Liked", "我喜欢"))
        } else {
            List {
                ForEach(tracks, id: \.id) { track in
                    SongObjectView(
                        title: track.title,
                        artist: track.artist,
                        durationLabel: songDuration(track.durationSeconds),
                        artwork: ArtworkSource.localHash(track.localArtworkHash ?? track.album?.artworkHash),
                        isSelected: selectedSongID == track.id,
                        isLossless: track.isLossless,
                        isLiked: true,
                        onToggleLike: { library.toggleLike(track) },
                        onSelect: { selectedSongID = track.id; play(track) },
                        onPlay: { play(track) }
                    )
                    .trackContextMenu(snapshot: TrackSnapshot(from: track),
                                      track: track,
                                      playlists: allPlaylists,
                                      onPlay: { play(track) })
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(tr("Liked", "我喜欢"))
            .safeAreaInset(edge: .bottom) {
                Button { playAll() } label: {
                    Label(tr("Play All", "播放全部"), systemImage: "play.fill")
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColors.magenta)
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
    }
    private func play(_ track: Track) {
        let snaps = tracks.map { TrackSnapshot(from: $0) }
        guard let snap = snaps.first(where: { $0.id == track.id }) else { return }
        playback.playTrack(snap, context: snaps, from: .songs)
    }
    private func playAll() {
        guard let first = tracks.first else { return }
        play(first)
    }
}

private func songDuration(_ s: Double) -> String {
    String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
}

