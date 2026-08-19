import SwiftUI

/// 全局搜索面板:中心浮层 + scrim,分 section 显示本地歌曲/专辑/艺术家 + YouTube 结果。
/// 克隆 QueueDrawerView 的 scrim+panel 模式,但居中而非 trailing。
struct GlobalSearchView: View {
    @Binding var isPresented: Bool
    @Binding var showLocalFolder: Bool
    @Binding var showYouTubeLink: Bool
    @Environment(GlobalSearchService.self) private var search
    @Environment(PlaybackService.self) private var playback
    @Environment(LibraryService.self) private var library
    @Environment(YouTubeImportService.self) private var importService
    @FocusState private var searchFieldFocused: Bool
    @State private var searchTab: SearchTab = .library

    enum SearchTab: String, CaseIterable {
        case library, youtubeMusic
        var label: String {
            switch self {
            case .library:     return tr("Library", "资料库")
            case .youtubeMusic: return tr("YouTube Music", "YouTube Music")
            }
        }
    }

    var body: some View {
        ZStack {
            // scrim — 点击关闭
            BrandColors.scrim
                .ignoresSafeArea()
                .onTapGesture { close() }

            panel
                .frame(width: 560)
                .frame(maxHeight: 520)
                .background(.ultraThinMaterial)
                .cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(BrandColors.hairline, lineWidth: 1))
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
        .onExitCommand { close() }
        .animation(.easeInOut(duration: 0.2), value: isPresented)
        .onAppear { searchFieldFocused = true }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            // 搜索栏
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(BrandColors.textSecondary)
                TextField(tr("Search songs, artists, albums, YouTube…", "搜索歌曲、艺术家、专辑、YouTube…"), text: Binding(
                    get: { search.query },
                    set: { search.query = $0 }
                ))
                .textFieldStyle(.plain)
                .focused($searchFieldFocused)
                .onSubmit { /* debounce 自动触发 */ }
                .onExitCommand { close() }
                .onKeyPress(.escape) {
                    close()
                    return .handled
                }

                if search.isSearchingYouTube {
                    ProgressView().controlSize(.small)
                }
                // P5 issue #6 — 「+」导入菜单仅在 Search 面板内。
                AddMusicMenu(showLocalFolder: $showLocalFolder, showYouTubeLink: $showYouTubeLink)
                Button { close() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(BrandColors.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            // 搜索来源切换:Library / YouTube Music
            Picker("", selection: $searchTab) {
                ForEach(SearchTab.allCases, id: \.self) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Divider().background(BrandColors.hairline)

            // 结果
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if searchTab == .library {
                        libraryResults
                    } else {
                        youtubeResults
                    }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.caption).fontWeight(.semibold)
                    .foregroundStyle(BrandColors.textSecondary)
                Text("\(count)").font(.caption2)
                    .foregroundStyle(BrandColors.textSecondary.opacity(0.6))
                Spacer()
            }
            content()
        }
    }

    // MARK: - Result panes

    @ViewBuilder
    private var libraryResults: some View {
        if !search.trackResults.isEmpty {
            section(title: tr("Songs", "歌曲"), count: search.trackResults.count) {
                ForEach(search.trackResults.prefix(8), id: \.id) { track in
                    GlobalSearchTrackRow(track: track) {
                        play(track, from: search.trackResults)
                    }
                }
            }
        }
        if !search.artistResults.isEmpty {
            section(title: tr("Artists", "艺术家"), count: search.artistResults.count) {
                ForEach(search.artistResults.prefix(5), id: \.id) { artist in
                    GlobalSearchArtistRow(artist: artist) {
                        navigateToArtist(artist)
                    }
                }
            }
        }
        if !search.albumResults.isEmpty {
            section(title: tr("Albums", "专辑"), count: search.albumResults.count) {
                ForEach(search.albumResults.prefix(6), id: \.id) { album in
                    GlobalSearchAlbumRow(album: album) {
                        navigateToAlbum(album)
                    }
                }
            }
        }
        if !search.noteResults.isEmpty {
            section(title: tr("Notes", "笔记"), count: search.noteResults.count) {
                ForEach(search.noteResults.prefix(8)) { hit in
                    GlobalSearchNoteRow(hit: hit) {
                        openNote(hit)
                    }
                }
            }
        }
        if search.query.trimmingCharacters(in: .whitespaces).isEmpty {
            Text(tr("Type to search your library", "输入关键词搜索资料库"))
                .font(.callout)
                .foregroundStyle(BrandColors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        } else if search.trackResults.isEmpty
                    && search.albumResults.isEmpty
                    && search.artistResults.isEmpty
                    && search.noteResults.isEmpty {
            Text(tr("No results", "无搜索结果"))
                .font(.callout)
                .foregroundStyle(BrandColors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        }
    }

    @ViewBuilder
    private var youtubeResults: some View {
        if !search.youtubeResults.isEmpty {
            section(title: "YouTube", count: search.youtubeResults.count) {
                ForEach(search.youtubeResults.prefix(8), id: \.id) { entry in
                    GlobalSearchYouTubeRow(entry: entry) {
                        Task { await playYouTube(entry) }
                    }
                }
            }
        } else if search.isSearchingYouTube {
            VStack(spacing: 12) {
                ProgressView()
                Text(tr("Searching YouTube Music…", "正在搜索 YouTube Music…"))
                    .font(.callout)
                    .foregroundStyle(BrandColors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else if search.query.trimmingCharacters(in: .whitespaces).isEmpty {
            Text(tr("Type to search YouTube Music", "输入关键词搜索 YouTube Music"))
                .font(.callout)
                .foregroundStyle(BrandColors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        } else {
            Text(tr("No results", "无搜索结果"))
                .font(.callout)
                .foregroundStyle(BrandColors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        }
    }

    // MARK: - Actions

    private func close() {
        search.reset()
        isPresented = false
    }

    private func play(_ track: Track, from tracks: [Track]) {
        let snaps = tracks.map { TrackSnapshot(from: $0) }
        guard let snap = snaps.first(where: { $0.id == track.id }) else { return }
        playback.playTrack(snap, context: snaps, from: .search)
        close()
    }

    private func navigateToArtist(_ artist: Artist) {
        NotificationCenter.default.post(name: .musesNavigateArtist, object: artist)
        close()
    }

    private func navigateToAlbum(_ album: Album) {
        NotificationCenter.default.post(name: .musesNavigateAlbum, object: album)
        close()
    }

    /// 笔记搜索命中:曲目笔记→播放该曲目并关闭;专辑笔记→跳转到该专辑并关闭。
    private func openNote(_ hit: NotesService.NoteSearchHit) {
        switch hit.kind {
        case .trackNote:
            guard let track = library.track(by: hit.ownerId) else { close(); return }
            play(track, from: [track])
        case .albumNote:
            guard let album = library.allAlbums().first(where: { $0.id == hit.ownerId }) else { close(); return }
            navigateToAlbum(album)
        }
    }

    private func playYouTube(_ entry: YTDlpBridge.YTDlpPlaylistEntry) async {
        guard let searchService = search.youTubeSearch else { return }
        do {
            let snap = try await searchService.importAsTrack(entry: entry)
            playback.playTrack(snap, context: [snap], from: .search)
        } catch {
            // 静默
        }
        close()
    }
}

// MARK: - Result rows

private struct GlobalSearchTrackRow: View {
    let track: Track
    let onPlay: () -> Void
    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 10) {
                ArtworkView(
                    source: ArtworkSource.localHash(track.localArtworkHash ?? track.album?.artworkHash),
                    cornerRadius: 4,
                    glyphSize: 16,
                    targetSize: 40
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
                    Text(track.artist).font(.caption).foregroundStyle(BrandColors.textSecondary).lineLimit(1)
                }
                Spacer()
                Text(String(format: "%d:%02d", Int(track.durationSeconds) / 60, Int(track.durationSeconds) % 60))
                    .font(.caption2).foregroundStyle(BrandColors.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

private struct GlobalSearchArtistRow: View {
    let artist: Artist
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ArtworkView(
                    source: ArtworkSource.localHash(artist.artworkHash),
                    glyphSize: 16,
                    clipCircle: true,
                    targetSize: 40
                )
                Text(artist.name).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

private struct GlobalSearchAlbumRow: View {
    let album: Album
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ArtworkView(
                    source: ArtworkSource.localHash(album.artworkHash),
                    cornerRadius: 4,
                    glyphSize: 16,
                    targetSize: 40
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(album.title).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
                    Text(album.albumArtist).font(.caption).foregroundStyle(BrandColors.textSecondary).lineLimit(1)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

private struct GlobalSearchYouTubeRow: View {
    let entry: YTDlpBridge.YTDlpPlaylistEntry
    let onPlay: () -> Void
    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 10) {
                AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(entry.id)/hqdefault.jpg")) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() }
                    else { Rectangle().fill(BrandColors.surface) }
                }
                .frame(width: 56, height: 32).cornerRadius(4).clipped()

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
                    Text(entry.uploader ?? "YouTube").font(.caption)
                        .foregroundStyle(BrandColors.textSecondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "play.circle").foregroundStyle(BrandColors.magenta)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

// MARK: - Navigation notifications

extension Notification.Name {
    static let musesNavigateArtist = Notification.Name("muses.navigateArtist")
    static let musesNavigateAlbum = Notification.Name("muses.navigateAlbum")
}

/// 笔记搜索命中行(Phase 21 §10.7):图标区分曲目/专辑笔记,显示 owner 标题 + 内容片段。
private struct GlobalSearchNoteRow: View {
    let hit: NotesService.NoteSearchHit
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(BrandColors.surface)
                        .frame(width: 32, height: 32)
                    Image(systemName: hit.kind == .trackNote ? "music.note.list" : "square.stack")
                        .font(.caption).foregroundStyle(BrandColors.magenta)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(hit.ownerTitle).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
                        .font(.callout)
                    Text(hit.snippet).font(.caption).foregroundStyle(BrandColors.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: hit.kind == .trackNote ? "play.circle" : "chevron.right")
                    .foregroundStyle(BrandColors.textSecondary).font(.caption)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}