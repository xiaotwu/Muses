import SwiftUI
import AppKit

/// Apple Music–style search page filling the main content slot.
struct GlobalSearchView: View {
    @Binding var isPresented: Bool
    @Binding var showLocalFolder: Bool
    @Binding var showYouTubeLink: Bool
    @Environment(GlobalSearchService.self) private var search
    @Environment(PlaybackService.self) private var playback
    @Environment(LibraryService.self) private var library
    @Environment(YouTubeImportService.self) private var importService
    @State private var escapeMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tr("Search", "搜索"))
                    .font(.system(size: AppleMusicTokens.pageTitleSize, weight: .heavy))
                    .foregroundStyle(BrandColors.textPrimary)
                Spacer()
                if search.isSearchingYouTube {
                    ProgressView().controlSize(.small)
                }
                AddMusicMenu(showLocalFolder: $showLocalFolder, showYouTubeLink: $showYouTubeLink)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            TextField(tr("Search", "搜索"), text: Binding(
                get: { search.query },
                set: { search.query = $0 }
            ))
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(BrandColors.surface, in: Capsule())
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    topResult
                    libraryResults
                    youtubeResults
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 100)
            }
        }
        .background(BrandColors.background)
        .onExitCommand { close() }
        .onAppear { installEscapeMonitor() }
        .onDisappear { removeEscapeMonitor() }
    }

    @ViewBuilder
    private var topResult: some View {
        if let entry = search.youtubeResults.first {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Top Result", "最佳结果"))
                    .font(.system(size: AppleMusicTokens.sectionTitleSize, weight: .semibold))
                    .foregroundStyle(BrandColors.textPrimary)
                GlobalSearchYouTubeRow(entry: entry) {
                    Task { await playYouTube(entry) }
                }
                .padding(12)
                .frame(maxWidth: 360, alignment: .leading)
                .background(BrandColors.surface, in: RoundedRectangle(cornerRadius: AppleMusicTokens.cardCorner, style: .continuous))
            }
        }
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                close()
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
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
            let context = TrackSnapshot.playbackContext(
                playing: snap, youTubeEntries: search.youtubeResults)
            playback.playTrack(snap, context: context, from: .search)
            close()
        } catch {
            // Keep the overlay open so a failed import is not mistaken for success.
        }
    }
}

// MARK: - Result rows

private struct GlobalSearchTrackRow: View {
    let track: Track
    let onPlay: () -> Void
    @Environment(PlaybackService.self) private var playback
    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 10) {
                ArtworkView(
                    source: ArtworkSource.resolve(for: track),
                    cornerRadius: 4,
                    glyphSize: 16,
                    targetSize: 40
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .foregroundStyle(playback.state.track?.id == track.id
                                         ? BrandColors.magenta : BrandColors.textPrimary)
                        .lineLimit(1)
                    Text(track.artist).font(.caption).foregroundStyle(BrandColors.textSecondary).lineLimit(1)
                }
                Spacer()
                Text(String(format: "%d:%02d", Int(track.durationSeconds) / 60, Int(track.durationSeconds) % 60))
                    .font(.caption2).foregroundStyle(BrandColors.textSecondary)
                SearchSourceIcon(systemName: track.source == .youtube ? "play.rectangle" : "music.note")
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
                SearchSourceIcon(systemName: "person")
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
                SearchSourceIcon(systemName: "square.stack")
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

private struct GlobalSearchYouTubeRow: View {
    let entry: YTDlpBridge.YTDlpPlaylistEntry
    let onPlay: () -> Void
    @Environment(LibraryService.self) private var library
    @Environment(PlaylistService.self) private var playlists

    private var isSaved: Bool {
        library.allTracks().contains { $0.youTubeId == entry.id }
            || playlists.fetchAll().contains { pl in
                (pl.items ?? []).contains { $0.track?.youTubeId == entry.id }
            }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPlay) {
                HStack(spacing: 10) {
                    CachedAsyncImage(
                        url: YouTubeThumbnail.url(videoId: entry.id),
                        content: { $0.resizable().scaledToFill() },
                        placeholder: { Rectangle().fill(BrandColors.surface) }
                    )
                    .frame(width: 56, height: 32).cornerRadius(4).clipped()

                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
                        Text(entry.uploader ?? "").font(.caption)
                            .foregroundStyle(BrandColors.textSecondary).lineLimit(1)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            if isSaved {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(BrandColors.green)
                    .help(tr("In library or a playlist", "已在资料库或歌单中"))
            }
            Button {
                if let url = URL(string: "https://music.youtube.com/watch?v=\(entry.id)") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Image(systemName: "arrow.up.right")
            }
            .buttonStyle(.plain)
            .help(tr("Open in browser", "在浏览器中打开"))
            .accessibilityLabel(tr("Open in browser", "在浏览器中打开"))
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

private struct SearchSourceIcon: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(BrandColors.textSecondary)
            .frame(width: 14)
            .accessibilityHidden(true)
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