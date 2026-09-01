import AppKit
import SwiftUI

enum GlobalSearchRoute {
    case section(SidebarSection)
    case release(CatalogReleaseProjection)
    case artist(CatalogArtistProjection)
}

/// Owns the presentation boundary of the single auxiliary Search window.
struct SearchWindowRoot: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showYouTubeLink = false

    var body: some View {
        GlobalSearchView(
            showYouTubeLink: $showYouTubeLink,
            onDismiss: close,
            onRoute: navigate
        )
        .sheet(isPresented: $showYouTubeLink) {
            AddYouTubeLinkSheet(isPresented: $showYouTubeLink)
        }
    }

    private func close() {
        dismissWindow(id: SearchWindowPolicy.sceneID)
    }

    private func navigate(_ route: GlobalSearchRoute) {
        NotificationCenter.default.post(name: .musesNavigateFromSearch, object: route)
        if MusesSingleInstance.orderFrontMainWindow() {
            close()
        }
    }
}

/// Compact Apple Music-style Search surface hosted in its own native window.
struct GlobalSearchView: View {
    @Binding var showYouTubeLink: Bool
    var onDismiss: () -> Void
    var onRoute: (GlobalSearchRoute) -> Void

    @Environment(GlobalSearchService.self) private var search
    @Environment(PlaybackService.self) private var playback
    @Environment(LibraryService.self) private var library
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var searchFieldFocused: Bool
    @State private var savedYouTubeIDs = Set<String>()

    private var trimmedQuery: String {
        search.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: SearchChromePolicy.panelCorner,
            style: .continuous
        )
        VStack(alignment: .leading, spacing: 0) {
            windowHeader
            VStack(alignment: .leading, spacing: 0) {
                searchChrome

                ScrollView {
                    Group {
                        if trimmedQuery.isEmpty {
                            searchLanding
                        } else {
                            searchResults
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, AppleMusicSpacing.related)
                    .padding(.bottom, SearchWindowPolicy.contentInset)
                }
            }
            .padding(.horizontal, SearchWindowPolicy.contentInset)
        }
        .frame(
            minWidth: SearchWindowPolicy.minimumWidth,
            minHeight: SearchWindowPolicy.minimumHeight
        )
        .musesGlass(in: shape, role: .floatingPanel)
        .clipShape(shape)
        .overlay(shape.stroke(BrandColors.textPrimary.opacity(0.14), lineWidth: 1))
        .background(SearchWindowConfigurator(colorScheme: colorScheme).frame(width: 0, height: 0))
        .ignoresSafeArea(edges: .top)
        .onExitCommand(perform: handleEscape)
        .onAppear {
            refreshSavedYouTubeIDs()
            searchFieldFocused = true
        }
    }

    private var windowHeader: some View {
        ZStack {
            Text(tr("Search Muses", "搜索 Muses"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BrandColors.textPrimary.opacity(0.82))
            HStack {
                Color.clear
                    .frame(width: WindowChromeMetrics.trafficLightClearanceWidth)
                    .allowsHitTesting(false)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: SearchWindowPolicy.draggableHeaderHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(BrandColors.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var searchChrome: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(BrandColors.textSecondary)
                        .accessibilityHidden(true)
                    TextField(tr("Artists, songs, albums, and videos", "艺术家、歌曲、专辑和视频"),
                              text: Binding(get: { search.query }, set: { search.query = $0 }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($searchFieldFocused)
                        .onSubmit(activateTopResult)
                    if search.isSearchingYouTube {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(tr("Searching YouTube Music", "正在搜索 YouTube Music"))
                    }
                    if !search.query.isEmpty {
                        Button {
                            search.query = ""
                            searchFieldFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(BrandColors.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help(tr("Clear Search", "清除搜索"))
                        .accessibilityLabel(tr("Clear Search", "清除搜索"))
                    }
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .frame(height: SearchWindowPolicy.controlHeight)
                .background(BrandColors.textPrimary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                Button { showYouTubeLink = true } label: {
                    Image(systemName: SearchChromePolicy.addMusicSystemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(BrandColors.textPrimary)
                        .frame(
                            width: SearchWindowPolicy.controlHeight,
                            height: SearchWindowPolicy.controlHeight
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .musesGlass(
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                    role: .compactControl
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(BrandColors.textPrimary.opacity(0.18), lineWidth: 1)
                }
                .help(tr("Paste YouTube Link", "粘贴 YouTube 链接"))
                .accessibilityLabel(tr("Add YouTube music", "添加 YouTube 音乐"))
            }

            Picker(tr("Search Source", "搜索来源"), selection: Binding(
                get: { search.scope }, set: { search.scope = $0 }
            )) {
                Text(tr("All", "全部")).tag(GlobalSearchScope.all)
                Text(tr("Library", "资料库")).tag(GlobalSearchScope.library)
                Text("YouTube Music").tag(GlobalSearchScope.youtube)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 430, minHeight: SearchWindowPolicy.sourceSegmentHeight,
                   maxHeight: SearchWindowPolicy.sourceSegmentHeight)
            .accessibilityLabel(tr("Search Source", "搜索来源"))
        }
        .padding(.top, SearchWindowPolicy.contentInset)
    }

    private var searchLanding: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(tr("Browse Your Music", "浏览你的音乐"))
                .font(.system(size: AppleMusicTokens.sectionTitleSize, weight: .semibold))
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
                                        detail: tr("\(artist.tracks.count) songs", "\(artist.tracks.count) 首歌曲"),
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
                    resultSection(title: "YouTube Music") {
                        LazyVStack(spacing: 0) {
                            ForEach(search.youtubeResults.prefix(16), id: \.id) { entry in
                                GlobalSearchYouTubeRow(entry: entry,
                                                       isSaved: savedYouTubeIDs.contains(entry.id)) {
                                    Task { await playYouTube(entry) }
                                }
                                .youTubeEntryContextMenu(entry: entry) {
                                    Task { await playYouTube(entry) }
                                }
                            }
                        }
                    }
                }
            }
        } else if search.isSearchingYouTube {
            SearchStatusView(
                systemName: "magnifyingglass",
                title: tr("Searching YouTube Music…", "正在搜索 YouTube Music…"),
                showsProgress: true
            )
        } else {
            SearchStatusView(
                systemName: "magnifyingglass",
                title: tr("No results for “\(trimmedQuery)”", "没有“\(trimmedQuery)”的结果"),
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
                .font(.system(size: AppleMusicTokens.sectionTitleSize, weight: .semibold))
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
        guard let searchService = search.youTubeSearch else { return }
        do {
            let snapshot = try await searchService.importAsTrack(entry: entry)
            savedYouTubeIDs.insert(entry.id)
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

/// Configures only the auxiliary Search window. AppKit continues to own and
/// position the standard traffic-light buttons in its native titlebar.
