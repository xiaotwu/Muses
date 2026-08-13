import SwiftUI
import AppKit
import SwiftData

struct LibraryView: View {
    @Binding var selection: SidebarSection
    @Binding var selectedAlbum: Album?
    @Environment(LibraryService.self) private var library

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
            let albums = library.allAlbums()
            if albums.isEmpty && progress.total == 0 {
                EmptyStateView(icon: "square.stack", title: tr("Library is empty", "资料库为空"),
                               subtitle: tr("Click + at the top-left to import a music folder, or drag files into the window", "点击左上角 + 导入音乐文件夹,或拖拽文件到窗口"))
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(albums, id: \.id) { album in
                        AlbumCard(album: album)
                            .onTapGesture { selectedAlbum = album }
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle(tr("Albums", "专辑"))
        .background(BrandColors.background)
    }
}

struct AlbumCard: View {
    let album: Album
    @Environment(LibraryService.self) private var library
    var body: some View {
        let _ = library.pinRevision
        let pinned = library.isPinned(album)
        VStack(alignment: .leading, spacing: 8) {
            let art = album.artworkHash.flatMap { ArtworkCache.default.path(forHash: $0) }
                .map { NSImage(byReferencing: $0) }
            if let img = art {
                Image(nsImage: img).resizable().scaledToFill()
                    .frame(width: 200, height: 200).clipped().cornerRadius(8)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(BrandColors.surface)
                    .frame(width: 200, height: 200).overlay(Image(systemName: "music.note"))
            }
            Text(album.title).font(.subheadline).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
            Text(album.albumArtist).font(.caption).foregroundStyle(BrandColors.textSecondary).lineLimit(1)
        }
        .contextMenu {
            Button(pinned ? tr("Unpin", "取消钉选") : tr("Pin", "钉选")) {
                library.togglePin(album)
            }
        }
    }
}

struct SongsListView: View {
    @Environment(LibraryService.self) private var library
    @Environment(PlaybackService.self) private var playback
    @Environment(PlaylistService.self) private var playlistService
    @Query(sort: \Playlist.name) private var allPlaylists: [Playlist]
    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var sortKey: SortKey = .title

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
        let tracks = sortedTracks(library.allTracks(search: debouncedSearch.isEmpty ? nil : debouncedSearch))
        Group {
            if tracks.isEmpty {
                EmptyStateView(
                    icon: "music.note",
                    title: searchText.isEmpty ? tr("No songs in library", "资料库中没有歌曲") : tr("No search results", "无搜索结果"),
                    subtitle: searchText.isEmpty ? tr("Click + at the top-left to import a music folder", "点击左上角 + 导入音乐文件夹") : nil)
            } else {
                List(tracks, id: \.id) { track in
                    SongRow(track: track,
                            playlists: allPlaylists,
                            onPlay: { play(track, from: tracks) },
                            onAddToQueue: { playback.queue.addToQueue(TrackSnapshot(from: track)) },
                            onPlayNext: { playback.queue.playNext(TrackSnapshot(from: track)) })
                        .tag(track.id)
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
}

/// 增强歌曲行:封面缩略图 + 标题 + 艺术家 + 专辑 + Hi-Res + 心心 + 时长 + 上下文菜单。
struct SongRow: View {
    let track: Track
    var playlists: [Playlist] = []
    var onPlay: () -> Void = {}
    var onAddToQueue: () -> Void = {}
    var onPlayNext: () -> Void = {}
    @Environment(LibraryService.self) private var library
    @Environment(PlaylistService.self) private var playlistService
    @State private var showEditTrack = false

    var body: some View {
        // 访问 likedRevision / metadataRevision 注册 @Observable 依赖,使 toggleLike / 编辑信息 后即时刷新。
        let _ = library.likedRevision
        let _ = library.metadataRevision
        let liked = library.isLiked(id: track.id)
        HStack(spacing: 10) {
            artwork.frame(width: 40, height: 40).cornerRadius(4)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
                Text(track.artist).font(.caption).foregroundStyle(BrandColors.textSecondary).lineLimit(1)
            }
            Spacer()
            Text(track.albumTitle ?? "").font(.caption)
                .foregroundStyle(BrandColors.textSecondary).lineLimit(1).frame(width: 160, alignment: .leading)
            if track.isLossless {
                Text("Hi-Res").font(.caption2).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(BrandColors.green.opacity(0.2))
                    .foregroundStyle(BrandColors.green).cornerRadius(4)
            }
            Button { library.toggleLike(track) } label: {
                Image(systemName: liked ? "heart.fill" : "heart").font(.caption)
            }
            .foregroundStyle(liked ? BrandColors.magenta : BrandColors.textSecondary)
            .buttonStyle(.plain)
            Text(formatDuration(track.durationSeconds)).foregroundStyle(BrandColors.textSecondary)
                .frame(width: 44, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onPlay() }
        .contextMenu {
            Button(tr("Play", "播放")) { onPlay() }
            Button(tr("Play Next", "下一首播放")) { onPlayNext() }
            Button(tr("Add to Queue", "加入队列")) { onAddToQueue() }
            Divider()
            Button(liked ? tr("Unlike", "取消收藏") : tr("Like", "收藏")) { library.toggleLike(track) }
            if !playlists.isEmpty {
                Divider()
                Menu(tr("Add to Playlist", "添加到歌单")) {
                    ForEach(playlists, id: \.id) { pl in
                        Button(pl.name) { playlistService.addTrack(pl, track: track) }
                    }
                }
            }
            Divider()
            Button(tr("Edit Info", "编辑信息")) { showEditTrack = true }
        }
        .sheet(isPresented: $showEditTrack) {
            EditTrackSheet(track: track)
        }
    }

    private var artwork: some View {
        Group {
            let hash = track.localArtworkHash ?? track.album?.artworkHash
            if let h = hash, let p = ArtworkCache.default.path(forHash: h) {
                Image(nsImage: NSImage(byReferencing: p)).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 4).fill(BrandColors.surface)
                    .overlay(Image(systemName: "music.note").font(.title3))
            }
        }
        .clipped()
    }

    private func formatDuration(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

struct LikedView: View {
    @Environment(LibraryService.self) private var library
    @Environment(PlaybackService.self) private var playback
    @Query(filter: #Predicate<Track> { $0.liked == true },
           sort: \Track.addedAt, order: .reverse)
    private var tracks: [Track]
    var body: some View {
        if tracks.isEmpty {
            EmptyStateView(icon: "heart", title: tr("No liked songs yet", "还没有收藏的歌曲"),
                           subtitle: tr("Tap ❤️ next to a song to like it", "点击歌曲旁的 ❤️ 收藏"))
                .navigationTitle(tr("Liked", "我喜欢"))
        } else {
            List {
                ForEach(tracks, id: \.id) { track in
                    TrackRow(track: track, showHeart: true)
                        .onTapGesture { play(track) }
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

