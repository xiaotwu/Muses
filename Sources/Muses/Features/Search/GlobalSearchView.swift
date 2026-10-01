import AppKit
import SwiftUI

enum GlobalSearchRoute {
    case section(SidebarSection)
    case release(CatalogReleaseProjection)
    case artist(CatalogArtistProjection)
}

/// Integrated search content sharing the main window and service graph.
struct GlobalSearchView: View {
    @Binding var showYouTubeLink: Bool
    var onDismiss: () -> Void
    var onRoute: (GlobalSearchRoute) -> Void

    @Environment(GlobalSearchService.self) private var search
    @Environment(PlaybackService.self) private var playback
    @Environment(LibraryService.self) private var library
    @FocusState private var searchFieldFocused: Bool
    @State private var savedYouTubeIDs = Set<String>()

    private var trimmedQuery: String {
        search.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("Search", "搜索"))
                .font(MusesTypography.pageTitle)
                .foregroundStyle(BrandColors.accent)
                .padding(.top, AppleMusicSpacing.pageTop)
                .padding(.horizontal, AppleMusicSpacing.pageHorizontal)
            VStack(alignment: .leading, spacing: 0) {
                searchChrome
                if search.musicCatalog.detail == nil, let error = search.additionalResultsStatus {
                    HStack {
                        Text(error).font(MusesTypography.callout)
                        Spacer()
                        Button(tr("Retry", "重试", zhHant: "重試"), systemImage: "arrow.clockwise") {
                            search.retrySearch()
                        }
                        .labelStyle(ActionIconLabelStyle())
                        .help(tr("Retry", "重试", zhHant: "重試"))
                        .disabled(search.isSearchingYouTube)
                    }.padding(.vertical, 10)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if trimmedQuery.isEmpty {
                            searchLanding
                        } else {
                            if search.scope.searchesYouTube { StructuredCatalogSearchView() }
                            if search.musicCatalog.detail == nil { searchResults }
                            if search.canLoadMore && search.musicCatalog.detail == nil {
                                Button(tr("Load more results", "加载更多结果", zhHant: "載入更多結果"), systemImage: "arrow.down.circle") {
                                    search.loadMore()
                                }
                                .labelStyle(ActionIconLabelStyle())
                                .help(tr("Load more results", "加载更多结果", zhHant: "載入更多結果"))
                                .disabled(search.isSearchingYouTube)
                                .padding()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, AppleMusicSpacing.related)
                    .padding(.bottom, OverlayChromeMetrics.scrollBottomInset)
                }
            }
            .padding(.horizontal, AppleMusicSpacing.pageHorizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BrandColors.background)
        .onExitCommand(perform: handleEscape)
        .onReceive(NotificationCenter.default.publisher(for: .musesFocusSearch)) { _ in
            searchFieldFocused = true
        }
        .onDisappear { if search.isSearchingYouTube { search.cancelSearch() } }
        .onAppear {
            if search.wasCancelled { search.retrySearch() }
            refreshSavedYouTubeIDs()
        }
        .task {
            await Task.yield()
            searchFieldFocused = true
        }
    }

    private var searchChrome: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(MusesTypography.system(size: 15, weight: .semibold))
                        .foregroundStyle(BrandColors.textSecondary)
                        .accessibilityHidden(true)
                    TextField(tr("Artists, songs, albums, and videos", "艺术家、歌曲、专辑和视频"),
                              text: Binding(get: { search.query }, set: { search.query = $0 }))
                        .textFieldStyle(.plain)
                        .font(MusesTypography.system(size: 15))
                        .focused($searchFieldFocused)
                        .onSubmit(activateTopResult)
                    if search.isSearchingYouTube {
                        Button { search.cancelSearch() } label: {
                            Image(systemName: "stop.circle")
                        }
                        .buttonStyle(.fullAreaPlain)
                        .help(tr("Cancel Search", "取消搜索", zhHant: "取消搜尋"))
                        .accessibilityLabel(tr("Cancel Search", "取消搜索", zhHant: "取消搜尋"))
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(tr("Searching YouTube", "正在搜索 YouTube", zhHant: "正在搜尋 YouTube"))
                    }
                    if !search.query.isEmpty {
                        Button {
                            search.query = ""
                            searchFieldFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(BrandColors.textSecondary)
                        }
                        .buttonStyle(.fullAreaPlain)
                        .help(tr("Clear Search", "清除搜索"))
                        .accessibilityLabel(tr("Clear Search", "清除搜索"))
                    }
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .frame(height: SearchPagePolicy.controlHeight)
                .background(BrandColors.textPrimary.opacity(0.06),
                            in: Capsule())

                Button { showYouTubeLink = true } label: {
                    Image(systemName: SearchChromePolicy.addMusicSystemImage)
                        .font(MusesTypography.system(size: 14, weight: .semibold))
                        .foregroundStyle(BrandColors.textPrimary)
                        .frame(
                            width: SearchPagePolicy.controlHeight,
                            height: SearchPagePolicy.controlHeight
                        )
                        .contentShape(Capsule())
                }
                .musesAction()
                .help(tr("Paste YouTube Link", "粘贴 YouTube 链接"))
                .accessibilityLabel(tr("Add YouTube music", "添加 YouTube 音乐"))
            }

            HStack(spacing: 6) {
                sourceButton(.all, title: tr("All", "全部"))
                sourceButton(.library, title: tr("Library", "资料库"))
                sourceButton(.youtube, title: "YouTube")
            }
            .padding(5)
            .musesGlass(in: Capsule(), role: .compactControl)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(tr("Search Source", "搜索来源"))
        }
        .padding(.top, SearchPagePolicy.contentInset)
    }

    private func sourceButton(_ scope: GlobalSearchScope, title: String) -> some View {
        Button { search.scope = scope } label: {
            Text(title)
                .font(MusesTypography.subheadline.weight(search.scope == scope ? .semibold : .regular))
                .foregroundStyle(search.scope == scope ? BrandColors.accent : BrandColors.textPrimary)
                .padding(.horizontal, 18)
                .frame(minHeight: SearchPagePolicy.sourceSegmentHeight)
        }
        .buttonStyle(.musesSegment(selected: search.scope == scope))
        .accessibilityAddTraits(search.scope == scope ? .isSelected : [])
        .help(title)
    }

    private var searchLanding: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(tr("Browse Your Music", "浏览你的音乐"))
                .font(MusesTypography.sectionTitle)
                .foregroundStyle(BrandColors.textPrimary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 14)],
                      spacing: 14) {
                SearchCategoryButton(title: tr("Songs", "歌曲"), systemName: "music.note") {
                    open(.songs)
                }
                SearchCategoryButton(title: tr("Albums", "专辑"), systemName: "square.stack") {
                    open(.albums)
                }
                SearchCategoryButton(title: tr("Artists", "艺术家"), systemName: "person.2") {
                    open(.artists)
                }
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if search.hasResults {
            LazyVStack(alignment: .leading, spacing: 30) {
                if !search.trackResults.isEmpty {
                    resultSection(title: tr("Songs", "歌曲")) {
                        LazyVStack(spacing: 0) {
                            ForEach(search.trackResults.prefix(12)) { snapshot in
                                GlobalSearchTrackRow(snapshot: snapshot,
                                                     isCurrent: playback.state.track?.id == snapshot.id) {
                                    play(snapshot, context: search.trackResults)
                                }
                                .trackContextMenu(snapshot: snapshot, onPlay: {
                                    play(snapshot, context: search.trackResults)
                                })
                            }
                        }
                    }
                }

                if !search.releaseResults.isEmpty {
                    resultSection(title: tr("Albums", "专辑")) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 18) {
                                ForEach(search.releaseResults.prefix(10)) { release in
                                    AlbumObjectView(
                                        title: release.title,
                                        subtitle: release.artistName,
                                        artwork: ArtworkSource.resolve(
                                            remoteURL: release.artworkURL,
                                            youTubeId: release.tracks.first?.youTubeId),
                                        size: 154,
                                        role: .browse,
                                        showsHoverPlay: !release.tracks.isEmpty,
                                        onSelect: { open(release) },
                                        onPlay: { playFirst(release.tracks, source: .album) }
                                    )
                                    .catalogReleaseContextMenu(
                                        release: release,
                                        onOpen: { open(release) },
                                        onPlay: { playFirst(release.tracks, source: .album) },
                                        onShuffle: {
                                            playFirst(release.tracks.shuffled(), source: .album)
                                        }
                                    )
                                }
                            }
                        }
                    }
                }

                if !search.catalogArtistResults.isEmpty {
                    resultSection(title: tr("Artists", "艺术家")) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 18) {
                                ForEach(search.catalogArtistResults.prefix(10)) { artist in
                                    ArtistObjectView(
                                        name: artist.name,
                                        detail: tr("\(artist.tracks.count) songs", "\(artist.tracks.count) 首歌曲", zhHant: "\(artist.tracks.count) 首歌曲"),
                                        artwork: ArtworkSource.resolve(
                                            remoteURL: artist.artworkURL,
                                            youTubeId: artist.tracks.first?.youTubeId),
                                        size: 154,
                                        showsHoverPlay: !artist.tracks.isEmpty,
                                        onSelect: { open(artist) },
                                        onPlay: { playFirst(artist.tracks, source: .artist) }
                                    )
                                    .catalogArtistContextMenu(
                                        artist: artist,
                                        onOpen: { open(artist) },
                                        onPlay: { playFirst(artist.tracks, source: .artist) },
                                        onShuffle: {
                                            playFirst(artist.tracks.shuffled(), source: .artist)
                                        }
                                    )
                                }
                            }
                        }
                    }
                }

                if !search.noteResults.isEmpty {
                    resultSection(title: tr("Notes", "笔记")) {
                        LazyVStack(spacing: 0) {
                            ForEach(search.noteResults.prefix(8)) { hit in
                                GlobalSearchNoteRow(hit: hit) { openNote(hit) }
                                    .trackContextMenu(
                                        snapshot: noteSnapshot(for: hit),
                                        onPlay: { openNote(hit) }
                                    )
                            }
                        }
                    }
                }

                if !search.youtubeResults.isEmpty {
                    resultSection(title: tr("YouTube · Additional results", "YouTube · 补充结果", zhHant: "YouTube · 補充結果")) {
                        LazyVStack(spacing: 0) {
                            ForEach(search.youtubeResults, id: \.id) { entry in
                                if entry.resourceKind == .video {
                                GlobalSearchYouTubeRow(entry: entry,
                                                       isSaved: savedYouTubeIDs.contains(entry.id)) {
                                    Task { await playYouTube(entry) }
                                }
                                .youTubeEntryContextMenu(entry: entry) {
                                    Task { await playYouTube(entry) }
                                }
                                } else if let url = entry.resourceURL {
                                    Button { NSWorkspace.shared.open(url) } label: {
                                        HStack {
                                            Image(systemName: entry.resourceKind == .channel ? "person.crop.circle" : "music.note.list")
                                            Text(entry.title)
                                            Spacer()
                                            Text(entry.resourceKind == .channel
                                                 ? tr("Channel", "频道", zhHant: "頻道")
                                                 : tr("Playlist", "歌单", zhHant: "播放清單"))
                                                .foregroundStyle(.secondary)
                                            Image(systemName: "arrow.up.right")
                                        }.padding(.vertical, 12).contentShape(Rectangle())
                                    }.buttonStyle(.fullAreaPlain)
                                    .help(tr("Open in YouTube", "在 YouTube 中打开", zhHant: "在 YouTube 中開啟"))
                                }
                            }
                        }
                    }
                }
            }
        } else if search.showsLibraryEmptyState {
            SearchStatusView(
                systemName: "magnifyingglass",
                title: tr("No results for “\(trimmedQuery)”", "没有“\(trimmedQuery)”的结果", zhHant: "沒有“\(trimmedQuery)”的結果"),
                subtitle: tr("Try another title, artist, album, or video.",
                             "请尝试其他歌曲名、艺术家、专辑或视频。")
            )
        }
    }

    private func resultSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(MusesTypography.sectionTitle)
                .foregroundStyle(BrandColors.textPrimary)
            content()
        }
    }

    private func open(_ section: SidebarSection) {
        search.reset()
        onRoute(.section(section))
    }

    private func open(_ release: CatalogReleaseProjection) {
        search.reset()
        onRoute(.release(release))
    }

    private func open(_ artist: CatalogArtistProjection) {
        search.reset()
        onRoute(.artist(artist))
    }

    private func play(_ snapshot: TrackSnapshot, context: [TrackSnapshot]) {
        playback.playTrack(snapshot, context: context, from: .search)
    }

    private func playFirst(_ tracks: [TrackSnapshot], source: QueueSource) {
        guard let first = tracks.first else { return }
        playback.playTrack(first, context: tracks, from: source)
    }

    private func openNote(_ hit: NotesService.NoteSearchHit) {
        guard let snapshot = noteSnapshot(for: hit) else { return }
        play(snapshot, context: [snapshot])
    }

    private func noteSnapshot(for hit: NotesService.NoteSearchHit) -> TrackSnapshot? {
        guard let track = library.track(by: hit.ownerId),
              !track.youTubeId.isEmpty else { return nil }
        return TrackSnapshot(from: track)
    }

    private func playYouTube(_ entry: YTDlpBridge.YTDlpPlaylistEntry) async {
        guard entry.resourceKind == .video else {
            if let url = entry.resourceURL { NSWorkspace.shared.open(url) }
            return
        }
        guard let searchService = search.youTubeSearch else { return }
        do {
            let snapshot = try await searchService.resolveTrack(entry: entry)
            let context = TrackSnapshot.playbackContext(
                playing: snapshot,
                youTubeEntries: search.youtubeResults
            )
            playback.playTrack(snapshot, context: context, from: .search)
        } catch {
            // Results remain visible so a failed import can be retried.
        }
    }

    private func refreshSavedYouTubeIDs() {
        savedYouTubeIDs = Set(library.allTracks().compactMap { track in
            guard !track.youTubeId.isEmpty else { return nil }
            return track.youTubeId
        })
    }

    private func activateTopResult() {
        if let snapshot = search.trackResults.first {
            play(snapshot, context: search.trackResults)
        } else if let release = search.releaseResults.first {
            open(release)
        } else if let artist = search.catalogArtistResults.first {
            open(artist)
        } else if let entry = search.youtubeResults.first {
            Task { await playYouTube(entry) }
        }
    }

    private func handleEscape() {
        if !search.query.isEmpty {
            search.reset()
            searchFieldFocused = true
        } else {
            onDismiss()
        }
    }
}
