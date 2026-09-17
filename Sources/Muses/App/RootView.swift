import SwiftUI
import AppKit
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(PrefKey.settingsLastPane) private var settingsPane = SettingsCategory.general.rawValue
    @State private var selectedChannelID: String?
    @State private var settingsPath: [SettingsDestination] = []
    @State private var navigationHistory = BrowseNavigationHistory()
    @State private var restoredBrowseRoute = false
    @State private var pendingAccountRestoration: BrowseRouteSnapshot?
    @Environment(GlobalSearchService.self) private var globalSearch
    @Environment(YouTubeAccountService.self) private var account
    @State private var collectionMemory = CollectionPresentationMemory()
    @Environment(ExternalPlaybackRouter.self) private var externalPlaybackRouter
    @Environment(LibraryService.self) private var library
    @Environment(PlaylistService.self) private var playlistService
    @Environment(PlaybackService.self) private var playback
    @Environment(YouTubeCatalogService.self) private var catalog
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var artworkWorld
    @State private var coverSlot: Anchor<CGRect>?
    @State private var section: SidebarSection = .home
    @State private var selectedPlaylist: Playlist?
    @State private var selectedYouTubeImport: YouTubeImport?
    @State private var selectedCatalogRelease: CatalogReleaseProjection?
    @State private var selectedCatalogArtist: CatalogArtistProjection?
    @State private var showYouTubeLink = false
    @State private var droppedYouTubeLink = ""
    @State private var showNowPlaying = false
    /// The visual layer remains mounted only for the 300ms opacity dismissal;
    /// logical presentation, hit testing, and accessibility stop immediately.
    @State private var nowPlayingOverlayMounted = false
    @State private var nowPlayingOverlayOpacity: Double = 0
    @State private var nowPlayingDismissTask: Task<Void, Never>?
    /// `true` means the dedicated lyrics-focus presentation is active after
    /// Now Playing has already been opened from the current artwork.
    @State private var nowPlayingShowLyrics = false
    @State private var windowWidth: CGFloat = 1440
    @State private var showQueue = false
    @State private var showLyricsDrawer = false
    @State private var showAudioInfo = false
    @AppStorage(PrefKey.language) private var language = "system"
    @AppStorage(PrefKey.nowPlayingLyricsMode) private var lyricsModeRaw: String = NowPlayingLyricsMode.inline.rawValue
    @Environment(\.libraryStoreFallback) private var libraryStoreFallback
    @State private var showStoreFallbackAlert = false
    @State private var showYouTubeVideo = false
    @AppStorage(PrefKey.nowPlayingMode) private var nowPlayingModeRaw: String = NowPlayingMode.cover.rawValue
    @AppStorage(PrefKey.sidebarCollapsed) private var isSidebarCollapsed = false

    private var lyricsFullscreen: Bool {
        (NowPlayingLyricsMode(rawValue: lyricsModeRaw) ?? .inline) != .inline
    }

    private var skipArtworkMorph: Bool {
        reduceMotion
            || lyricsFullscreen
            || playback.state.track?.id == nil
            || windowWidth < 960
    }

    var body: some View {
        notificationWired
            .toolbar { windowNavigationToolbar }
            .modifier(MainWindowTitleHidden())
            .alert(tr("Unable to Open Link", "无法打开链接", zhHant: "無法開啟連結"), isPresented: Binding(
                get: { externalPlaybackRouter.errorMessage != nil },
                set: { if !$0 { externalPlaybackRouter.errorMessage = nil } }
            )) {
                Button(tr("OK", "好")) { externalPlaybackRouter.errorMessage = nil }
            } message: { Text(externalPlaybackRouter.errorMessage ?? "") }
            .onChange(of: browseRoute) { _, route in
                navigationHistory.visit(route)
                pendingAccountRestoration = nil
                if !libraryStoreFallback {
                    BrowseRouteSnapshot(route: route, accountChannelID: account.activeChannelID).save()
                }
            }
            .onChange(of: account.activeChannelID) { previous, current in
                globalSearch.reset()
                if let snapshot = pendingAccountRestoration, current != nil {
                    pendingAccountRestoration = nil
                    if let route = snapshot.route(activeChannelID: current) {
                        applyBrowseRoute(route)
                        navigationHistory = BrowseNavigationHistory(initial: browseRoute)
                    } else if !libraryStoreFallback {
                        BrowseRouteSnapshot(route: browseRoute, accountChannelID: current).save()
                    }
                }
                if previous != nil && previous != current { clearPrivateNavigation() }
            }
            .onChange(of: account.isConnected) { _, connected in
                if !connected { globalSearch.reset(); clearPrivateNavigation() }
            }
            .onAppear {
                if MusesSingleInstance.pendingVideoPresentation {
                    MusesSingleInstance.pendingVideoPresentation = false
                    showYouTubeVideo = playback.videoSession != nil
                }
            }
            .onChange(of: showYouTubeVideo) { _, shown in
                if !shown, let surface = playback.videoSession?.surface, !surface.isFloating {
                    surface.close()
                }
            }
            .onDisappear {
                if let surface = playback.videoSession?.surface, !surface.isFloating {
                    surface.close()
                }
            }
    }

    private var browseRoute: BrowseRoute {
        if section == .subscriptions, let selectedChannelID { return .channel(selectedChannelID) }
        if section == .settings { return .settings(settingsPane, settingsPath) }
        if section == .playlists, let selectedPlaylist { return .playlist(selectedPlaylist.id) }
        if section == .playlists, let selectedYouTubeImport { return .youTubeImport(selectedYouTubeImport.id) }
        if section == .albums, let selectedCatalogRelease { return .release(selectedCatalogRelease.stableID) }
        if section == .artists, let selectedCatalogArtist { return .artist(selectedCatalogArtist.stableID) }
        return .section(section)
    }

    @ToolbarContentBuilder
    private var windowNavigationToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                withAnimation(MusesMotion.drawerAnimation(reduceMotion: reduceMotion)) {
                    isSidebarCollapsed.toggle()
                }
            } label: {
                Label(tr("Toggle Sidebar", "切换边栏", zhHant: "切換側邊欄"), systemImage: "sidebar.leading")
            }
            .help(tr("Toggle Sidebar", "切换边栏", zhHant: "切換側邊欄"))
            Button {
                if showNowPlaying { showNowPlaying = false }
                else { navigateHistory(back: true) }
            } label: {
                Label(tr("Back", "后退", zhHant: "返回"), systemImage: "arrow.left")
            }
            .help(tr("Back", "后退", zhHant: "返回"))
            .keyboardShortcut("[", modifiers: .command)
            .disabled((!showNowPlaying && !navigationHistory.canGoBack) || showYouTubeVideo)
            Button { navigateHistory(back: false) } label: {
                Label(tr("Forward", "前进", zhHant: "前進"), systemImage: "arrow.right")
            }
            .help(tr("Forward", "前进", zhHant: "前進"))
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!navigationHistory.canGoForward || showNowPlaying || showYouTubeVideo)
        }
    }

    private func navigateHistory(back: Bool) {
        guard let route = back ? navigationHistory.back() : navigationHistory.forward() else { return }
        applyBrowseRoute(route)
        navigationHistory.replaceCurrent(browseRoute)
    }

    private func applyBrowseRoute(_ route: BrowseRoute) {
        selectedPlaylist = nil
        selectedYouTubeImport = nil
        selectedCatalogRelease = nil
        selectedCatalogArtist = nil
        selectedChannelID = nil
        switch route {
        case .channel(let id):
            section = .subscriptions
            selectedChannelID = id
        case .settings(let category, let path):
            section = .settings
            settingsPane = category
            settingsPath = path
        case .section(let destination): section = destination
        case .playlist(let id):
            section = .playlists
            selectedPlaylist = try? modelContext.fetch(FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })).first
        case .youTubeImport(let id):
            section = .playlists
            selectedYouTubeImport = try? modelContext.fetch(FetchDescriptor<YouTubeImport>(predicate: #Predicate { $0.id == id })).first
        case .release(let id):
            section = .albums
            selectedCatalogRelease = catalog.release(byStableID: id)
        case .artist(let id):
            section = .artists
            selectedCatalogArtist = catalog.artist(byStableID: id)
        }
        // A deleted destination resolves to its overview instead of a stale model.
    }

    private func clearPrivateNavigation() {
        pendingAccountRestoration = nil
        if section == .subscriptions { applyBrowseRoute(.section(.home)) }
        // Do not retain private destinations in the back/forward stack across accounts.
        navigationHistory = BrowseNavigationHistory(initial: browseRoute)
        if !libraryStoreFallback {
            BrowseRouteSnapshot(route: browseRoute, accountChannelID: account.activeChannelID).save()
        }
    }

    private var notificationWired: some View {
        navigationWired
            .onReceive(NotificationCenter.default.publisher(for: .musesOpenSettings)) { note in
                if let category = note.object as? SettingsCategory {
                    UserDefaults.standard.set(category.destination.rawValue, forKey: PrefKey.settingsLastPane)
                }
                openIntegratedSettings()
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard urls.count == 1, let url = urls.first,
                      let target = YouTubeShareTarget(url: url),
                      target.kind == .video || target.kind == .playlist else { return false }
                droppedYouTubeLink = url.absoluteString
                showYouTubeLink = true
                return true
            }
            .onAppear(perform: handleAppear)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if NSApp.keyWindow == nil {
                    MusesSingleInstance.orderFrontMainWindow()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .musesToggleQueue)) { _ in
                if showNowPlaying {
                    showNowPlaying = false
                }
                showQueue.toggle()
                if showQueue { showLyricsDrawer = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: .musesToggleNowPlaying)) { _ in
                if showNowPlaying {
                    showNowPlaying = false
                } else {
                    openNowPlaying()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .musesFocusSearch)) { _ in
                openWindow(id: SearchWindowPolicy.sceneID)
            }
            .onChange(of: section) { _, new in
                applySidebarSectionChange(new)
            }
            .onReceive(NotificationCenter.default.publisher(for: .musesToggleAudioInfo)) { _ in
                showAudioInfo.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .musesToggleLyrics)) { _ in
                handleDockLyrics()
            }
            .onReceive(NotificationCenter.default.publisher(for: .musesShowYouTubeVideo)) { _ in
                guard playback.state.track?.youTubeId != nil else { return }
                MusesSingleInstance.pendingVideoPresentation = false
                showYouTubeVideo = true
            }
    }

    private var navigationWired: some View {
        sheetHost
            .onReceive(NotificationCenter.default.publisher(for: .musesSelectPlaylist)) { note in
                if let playlist = note.object as? Playlist { selectedPlaylist = playlist }
            }
            .onReceive(NotificationCenter.default.publisher(for: .musesNavigateYouTubeImport)) { note in
                if let ytImport = note.object as? YouTubeImport { selectedYouTubeImport = ytImport }
            }
            .onReceive(NotificationCenter.default.publisher(for: .musesCloseYouTubeAlbum)) { _ in
                selectedYouTubeImport = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .musesShowPlaylistsOverview)) { _ in
                selectedPlaylist = nil
                selectedYouTubeImport = nil
                section = .playlists
            }
            .onReceive(NotificationCenter.default.publisher(for: .musesNavigateFromSearch)) { note in
                guard let route = note.object as? GlobalSearchRoute else { return }
                applySearchRoute(route)
            }
            .onReceive(NotificationCenter.default.publisher(for: .musesNavigateToRelease)) { note in
                selectedPlaylist = nil
                selectedYouTubeImport = nil
                selectedCatalogArtist = nil
                if let release = note.object as? CatalogReleaseProjection {
                    selectedCatalogRelease = release
                    section = .albums
                } else if let id = note.object as? String,
                          let release = catalog.release(byStableID: id) ?? catalog.release(byTitle: id) {
                    selectedCatalogRelease = release
                    section = .albums
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .musesNavigateToArtist)) { note in
                selectedPlaylist = nil
                selectedYouTubeImport = nil
                selectedCatalogRelease = nil
                if let artist = note.object as? CatalogArtistProjection {
                    selectedCatalogArtist = artist
                    section = .artists
                } else if let id = note.object as? String,
                          let artist = catalog.artist(byStableID: id) ?? catalog.artist(byName: id) {
                    selectedCatalogArtist = artist
                    section = .artists
                }
            }
    }

    private var sheetHost: some View {
        alertHost
            .sheet(isPresented: $showAudioInfo) {
                AudioInfoPanel()
                    .tint(BrandColors.accent)
            }
    }

    private var alertHost: some View {
        continuityChrome(splitView)
            .alert(
                tr("Library could not be opened", "无法打开资料库"),
                isPresented: $showStoreFallbackAlert
            ) {
                Button(tr("OK", "好")) { showStoreFallbackAlert = false }
            } message: {
                Text(tr(
                    "Muses could not open your on-disk library and is using a temporary empty session. Your original library was copied to a muses-corrupt backup in Application Support and was not deleted. Quit other Muses instances and relaunch. If this keeps happening, restore the backup.",
                    "Muses 无法打开磁盘上的资料库,当前使用临时空白会话。原始库已备份为 Application Support 中的 muses-corrupt 副本,未被删除。请退出其他 Muses 实例后重新启动。若反复出现,请从备份恢复。"
                ))
            }
    }

    private func applySearchRoute(_ route: GlobalSearchRoute) {
        MusesSingleInstance.pendingSearchRoute = nil
        selectedPlaylist = nil
        selectedYouTubeImport = nil
        switch route {
        case .section(let destination):
            selectedCatalogRelease = nil
            selectedCatalogArtist = nil
            section = destination == .search ? .home : destination
        case .release(let release):
            selectedCatalogArtist = nil
            selectedCatalogRelease = release
            section = .albums
        case .artist(let artist):
            selectedCatalogRelease = nil
            selectedCatalogArtist = artist
            section = .artists
        }
    }

    private func openIntegratedSettings() {
        MusesSingleInstance.pendingSettings = false
        settingsPath = []
        showNowPlaying = false
        showYouTubeVideo = false
        showQueue = false
        showLyricsDrawer = false
        selectedPlaylist = nil
        selectedYouTubeImport = nil
        selectedCatalogRelease = nil
        selectedCatalogArtist = nil
        section = .settings
    }

    private func handleAppear() {
        if !restoredBrowseRoute {
            restoredBrowseRoute = true
            if !libraryStoreFallback, !MusesSingleInstance.pendingSettings,
               MusesSingleInstance.pendingSearchRoute == nil,
               let snapshot = BrowseRouteSnapshot.read() {
                if snapshot.requiresAccount && account.isConnected && account.activeChannelID == nil {
                    pendingAccountRestoration = snapshot
                } else if let route = snapshot.route(activeChannelID: account.activeChannelID) {
                    applyBrowseRoute(route)
                    navigationHistory = BrowseNavigationHistory(initial: browseRoute)
                }
            }
        }
        if MusesSingleInstance.pendingSettings { openIntegratedSettings() }
        if let route = MusesSingleInstance.pendingSearchRoute { applySearchRoute(route) }
        if libraryStoreFallback { showStoreFallbackAlert = true }
        DispatchQueue.main.async {
            MusesSingleInstance.orderFrontMainWindow()
        }
    }

    /// Sidebar items must replace pushed album/artist/playlist detail. Playlist
    /// rows set `section` to `.playlists` *after* selecting a playlist, so that
    /// destination keeps playlist / YouTube-import context.
    private func applySidebarSectionChange(_ new: SidebarSection) {
        if new != .albums { selectedCatalogRelease = nil }
        if new != .artists { selectedCatalogArtist = nil }
        if SidebarDetailClearPolicy.policy(for: new) == .clearAll {
            selectedPlaylist = nil
            selectedYouTubeImport = nil
        }
    }

    private let chromeTop: CGFloat = 0
    private let chromeSide: CGFloat = 0
    private var chromeBottom: CGFloat {
        if showYouTubeVideo { return 0 }
        if showNowPlaying, NowPlayingChromePolicy.hidesDock { return 0 }
        return AppleMusicTokens.capsuleHeight + AppleMusicTokens.playerBottomMargin
    }
    private var splitView: some View {
        HStack(spacing: 0) {
            SidebarView(selection: $section,
                        selectedPlaylist: $selectedPlaylist,
                        selectedYouTubeImport: $selectedYouTubeImport,
                        isCollapsed: $isSidebarCollapsed,
                        onSettingsCategoryChange: { settingsPath = [] })
            ZStack(alignment: .bottom) {
                detailStack
                    .environment(\.collectionPresentation, collectionMemory.entry(for: browseRoute))
                    .id(section == .settings ? BrowseRoute.section(.settings) : browseRoute)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(BrowseBackground())
                if !showYouTubeVideo,
                   !(showNowPlaying && NowPlayingChromePolicy.hidesDock) {
                    PlayerBar(lyricsActive: showLyricsDrawer,
                              queueActive: showQueue,
                              onArtworkTap: { openNowPlaying() },
                              onLyricsTap: { handleDockLyrics() },
                              onQueueTap: {
                                  withAnimation(MusesMotion.drawerAnimation(reduceMotion: reduceMotion)) {
                                      showQueue.toggle()
                                      if showQueue { showLyricsDrawer = false }
                                  }
                              },
                              onVideoTap: { showYouTubeVideo = true })
                        .padding(.horizontal, AppleMusicTokens.playerHorizontalMargin)
                        .padding(.bottom, AppleMusicTokens.playerBottomMargin)
                }
            }
            if !showNowPlaying {
                if showLyricsDrawer {
                    LyricsDrawerView(isPresented: $showLyricsDrawer)
                        .transition(.move(edge: .trailing))
                }
                if showQueue {
                    QueueDrawerView(isPresented: $showQueue, showsScrim: false)
                        .ignoresSafeArea(.container, edges: [.top, .bottom])
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .background(BrandColors.background)
        .background {
            MainWindowConfigurator()
                .frame(width: 0, height: 0)
        }
        .ignoresSafeArea(edges: [.bottom, .leading])
        .tint(BrandColors.accent)
        .accessibilityHidden(showNowPlaying || showYouTubeVideo)
        .disabled(showYouTubeVideo)
    }

    private func openNowPlaying() {
        guard NowPlayingChromePolicy.canOpen(hasTrack: playback.state.track != nil) else { return }
        showQueue = false
        showLyricsDrawer = false
        nowPlayingShowLyrics = false
        nowPlayingDismissTask?.cancel()
        nowPlayingOverlayMounted = true
        withAnimation(MusesMotion.morphAnimation(reduceMotion: reduceMotion)) {
            nowPlayingOverlayOpacity = 1
            showNowPlaying = true
        }
    }

    private func handleDockLyrics() {
        guard NowPlayingChromePolicy.canOpen(hasTrack: playback.state.track != nil) else { return }
        showQueue = false
        switch DockLyricsPolicy.action(nowPlayingOpen: showNowPlaying) {
        case .toggleDrawer:
            showLyricsDrawer.toggle()
        case .toggleLyricsFocus:
            lyricsModeRaw = lyricsFullscreen ? NowPlayingLyricsMode.inline.rawValue : NowPlayingLyricsMode.lyricsOnly.rawValue
            nowPlayingShowLyrics = true
        }
    }

    @ViewBuilder
    private var detailStack: some View {
        if let playlist = selectedPlaylist {
            PlaylistDetailView(playlist: playlist, selectedPlaylist: $selectedPlaylist)
        } else if let ytImport = selectedYouTubeImport {
            YouTubeAlbumDetailView(youTubeImport: ytImport)
        } else if let release = selectedCatalogRelease {
            CatalogReleaseDetailView(release: release, selection: $selectedCatalogRelease)
        } else if let artist = selectedCatalogArtist {
            CatalogArtistDetailView(artist: artist, selection: $selectedCatalogArtist)
        } else {
            switch section {
            case .home:
                HomeView()
            case .new:
                NewView()
            case .search:
                HomeView()
            case .albums:
                CatalogReleasesView(selection: $selectedCatalogRelease)
            case .artists:
                CatalogArtistsView(selection: $selectedCatalogArtist)
            case .songs:
                SongsListView()
            case .liked:
                SongsListView(filter: .liked)
            case .musicVideos:
                SongsListView(filter: .musicVideos)
            case .subscriptions:
                YouTubeSubscriptionsView(selectedChannelID: $selectedChannelID)
            case .playlists:
                PlaylistsView(selectedPlaylist: $selectedPlaylist)
            case .history:
                HistoryView()
            case .settings:
                SettingsPage(path: $settingsPath)
            }
        }
    }

    private func continuityChrome<Content: View>(_ content: Content) -> some View {
        content
            .environment(\.artworkWorldNamespace, artworkWorld)
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: RootWindowWidthKey.self, value: geo.size.width)
                }
            }
            .onPreferenceChange(RootWindowWidthKey.self) { windowWidth = $0 }
            .overlay {
                if nowPlayingOverlayMounted, NowPlayingChromePolicy.coversWindow {
                    nowPlayingLayers
                        .tint(BrandColors.accent)
                } else {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: chromeTop)
                            .allowsHitTesting(false)
                        nowPlayingLayers
                        Color.clear.frame(height: showYouTubeVideo ? 0 : chromeBottom)
                            .allowsHitTesting(false)
                    }
                    .tint(BrandColors.accent)
                }
            }
            .overlay {
                if showYouTubeLink {
                    ZStack {
                        BrandColors.scrim
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { showYouTubeLink = false }
                        AddYouTubeLinkSheet(isPresented: $showYouTubeLink, initialURL: droppedYouTubeLink)
                    }
                    .tint(BrandColors.accent)
                }
            }
            .animation(MusesMotion.drawerAnimation(reduceMotion: reduceMotion), value: isSidebarCollapsed)
            .animation(MusesMotion.drawerAnimation(reduceMotion: reduceMotion), value: showQueue)
            .animation(MusesMotion.drawerAnimation(reduceMotion: reduceMotion), value: showLyricsDrawer)
            .animation(MusesMotion.overlayAnimation(reduceMotion: reduceMotion), value: showYouTubeVideo)
            .overlay {
                if showYouTubeVideo,
                   let videoId = playback.state.track?.youTubeId {
                    YouTubeVideoOverlay(videoId: videoId, isPresented: $showYouTubeVideo)
                        .tint(BrandColors.accent)
                }
            }
            .onChange(of: showNowPlaying) { _, open in
                if open {
                    nowPlayingDismissTask?.cancel()
                    nowPlayingOverlayMounted = true
                    if nowPlayingOverlayOpacity < 1 {
                        withAnimation(MusesMotion.morphAnimation(reduceMotion: reduceMotion)) {
                            nowPlayingOverlayOpacity = 1
                        }
                    }
                    showQueue = false
                    showLyricsDrawer = false
                } else {
                    nowPlayingShowLyrics = false
                    restorePlayerArtworkFocus()
                    nowPlayingDismissTask?.cancel()
                    if reduceMotion {
                        nowPlayingOverlayOpacity = 0
                        nowPlayingOverlayMounted = false
                    } else {
                        withAnimation(.easeOut(
                            duration: NowPlayingPresentationPolicy.dismissDuration
                        )) {
                            nowPlayingOverlayOpacity = 0
                        }
                        nowPlayingDismissTask = Task { @MainActor in
                            try? await Task.sleep(for: .seconds(
                                NowPlayingPresentationPolicy.dismissDuration
                            ))
                            guard !Task.isCancelled, !showNowPlaying else { return }
                            nowPlayingOverlayMounted = false
                        }
                    }
                }
            }
    }

    /// Back → middle → front: environment gradient, chrome, live-cover host.
    private var nowPlayingLayers: some View {
        GeometryReader { _ in
            ZStack {
                if nowPlayingOverlayMounted {
                    NowPlayingEnvironmentLayer()
                        .zIndex(0)
                    NowPlayingView(isPresented: $showNowPlaying,
                                   showLyrics: $nowPlayingShowLyrics,
                                   coverHostedExternally: showNowPlaying && !skipArtworkMorph)
                        .zIndex(1)
                }
            }
            .overlayPreferenceValue(CoverSlotPreferenceKey.self) { anchor in
                GeometryReader { slotProxy in
                    liveCoverHost(proxy: slotProxy, anchor: anchor)
                        .background(CoverSlotBinder(anchor: anchor, storage: $coverSlot))
                }
                .allowsHitTesting(false)
            }
        }
        .opacity(nowPlayingOverlayOpacity)
        .allowsHitTesting(NowPlayingPresentationPolicy.acceptsInteraction(
            isPresented: showNowPlaying
        ))
        .accessibilityHidden(!NowPlayingPresentationPolicy.isAccessibilityVisible(
            isPresented: showNowPlaying
        ))
    }

    @ViewBuilder
    private func liveCoverHost(proxy: GeometryProxy, anchor: Anchor<CGRect>?) -> some View {
        if showNowPlaying, !skipArtworkMorph,
           let trackID = playback.state.track?.id {
            let resolvedSize = anchor.map { anchor in
                let rect = proxy[anchor]
                return min(rect.width, rect.height)
            } ?? PlayerDockMetrics.art
            let host = LiveCoverHost(
                source: ArtworkSource.resolve(for: playback.state.track),
                trackID: trackID,
                namespace: artworkWorld,
                size: resolvedSize,
                isSource: showNowPlaying,
                isPresented: showNowPlaying
            )
            if let anchor {
                let rect = proxy[anchor]
                host
                    .frame(width: rect.width, height: rect.height)
                    .scaleEffect(playback.state.isPlaying && !reduceMotion ? 1.06 : 1.0)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35),
                               value: playback.state.isPlaying)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
    }

    private func restorePlayerArtworkFocus() {
        Task { @MainActor in
            // PlayerBar re-enters the hierarchy when `showNowPlaying` flips.
            // Yield once so its artwork button can receive the focus request.
            await Task.yield()
            guard !showNowPlaying else { return }
            NotificationCenter.default.post(name: .musesRestorePlayerArtworkFocus, object: nil)
        }
    }
}

private struct RootWindowWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 1440
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// `Anchor` is not Equatable, so `onPreferenceChange` cannot store it. Overlay
/// positioning uses the preference value directly; this keeps `coverSlot` in sync.
private struct CoverSlotBinder: View {
    let anchor: Anchor<CGRect>?
    @Binding var storage: Anchor<CGRect>?
    var body: some View {
        Color.clear
            .task(id: anchor == nil ? 0 : 1) {
                storage = anchor
            }
    }
}

enum SidebarSection: String, Hashable, CaseIterable {
    case search, home, new
    case artists, albums, songs, liked, musicVideos, subscriptions  // Unified library destinations
    case playlists
    case settings
    case history  // Phase 17: Smart Listening History

    var title: String {
        switch self {
        case .search: return tr("Search", "搜索")
        case .home: return tr("Home", "首页")
        case .new: return SidebarNavPolicy.newTitle()
        case .artists: return tr("Artists", "艺术家")
        case .albums: return tr("Albums", "专辑")
        case .songs: return tr("Songs", "歌曲")
        case .liked: return tr("Favorites", "收藏")
        case .musicVideos: return tr("Music Videos", "音乐视频")
        case .subscriptions: return tr("Subscriptions", "订阅")
        case .playlists: return tr("Playlists", "歌单")
        case .history: return tr("History", "历史记录")
        case .settings: return tr("Settings", "设置", zhHant: "設定")
        }
    }
}

/// Which pushed details survive a sidebar section change.
enum SidebarDetailClearPolicy: Equatable {
    case keepPlaylistContext
    case clearAll

    static func policy(for section: SidebarSection) -> SidebarDetailClearPolicy {
        section == .playlists ? .keepPlaylistContext : .clearAll
    }
}

private struct LibraryStoreFallbackKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when Muses opened an empty in-memory store because the on-disk library failed.
    var libraryStoreFallback: Bool {
        get { self[LibraryStoreFallbackKey.self] }
        set { self[LibraryStoreFallbackKey.self] = newValue }
    }
}

extension Notification.Name {
    static let musesToggleQueue = Notification.Name("muses.toggleQueue")
    static let musesToggleNowPlaying = Notification.Name("muses.toggleNowPlaying")
    static let musesFocusSearch = Notification.Name("muses.focusSearch")
    static let musesNavigateFromSearch = Notification.Name("muses.navigateFromSearch")
    static let musesNavigateToRelease = Notification.Name("muses.navigateToRelease")
    static let musesNavigateToArtist = Notification.Name("muses.navigateToArtist")
    static let musesNavigateYouTubeImport = Notification.Name("muses.navigateYouTubeImport")
    static let musesCloseYouTubeAlbum = Notification.Name("muses.closeYouTubeAlbum")
    static let musesShowPlaylistsOverview = Notification.Name("muses.showPlaylistsOverview")
    static let musesOpenSettings = Notification.Name("muses.openSettings")
    static let musesToggleLyrics = Notification.Name("muses.toggleLyrics")
    static let musesShowYouTubeVideo = Notification.Name("muses.showYouTubeVideo")
    // Desktop integration notifications (mini player, desktop lyrics).
    static let musesOpenMiniPlayer = Notification.Name("muses.openMiniPlayer")
    static let musesToggleDesktopLyrics = Notification.Name("muses.toggleDesktopLyrics")
    static let musesDesktopFlagsChanged = Notification.Name("muses.desktopFlagsChanged")
    // Audio info panel toggle.
    static let musesToggleAudioInfo = Notification.Name("muses.toggleAudioInfo")
}

enum BrandColors {
    /// Dynamic theme colors: Apple Music near-black in dark mode and a restrained light palette.
    /// Uses `NSColor(name:dynamicProvider:)` so every call site follows appearance changes with no extra code.
    private static func dynamic(_ dark: NSColor, _ light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { (appearance: NSAppearance) -> NSColor in
            // `appearance.name == .darkAqua` matches only the standard dark appearance and would
            // miss variants like high-contrast dark (.accessibilityHighContrastDarkAqua) and
            // vibrantDark, causing those variants to wrongly take the light branch (near-black
            // light text on a dark background would be unreadable).
            // `bestMatch` returns the first standard appearance matched in the appearance
            // hierarchy, covering all dark variants.
            let darkMatches: [NSAppearance.Name] = [
                .darkAqua,
                .vibrantDark,
                .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastVibrantDark
            ]
            return appearance.bestMatch(from: darkMatches) != nil ? dark : light
        })
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1.0) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// Measured Apple Music Web page fill (`body` #1F1F1F dark / white light).
    static let background = dynamic(
        rgb(AppleMusicTokens.darkPageRGB.r,
            AppleMusicTokens.darkPageRGB.g,
            AppleMusicTokens.darkPageRGB.b),
        rgb(AppleMusicTokens.lightPageRGB.r,
            AppleMusicTokens.lightPageRGB.g,
            AppleMusicTokens.lightPageRGB.b)
    )
    /// Card/surface color: slightly elevated above the page background.
    static let surface = dynamic(
        rgb(0.15, 0.15, 0.17),
        rgb(0.92, 0.92, 0.94)
    )
    /// Adaptive monochrome selection accent. YouTube and destructive colors stay semantic.
    static let accent = dynamic(rgb(0.98, 0.98, 0.99), rgb(0.06, 0.06, 0.07))
    static let textPrimary = dynamic(
        rgb(0.94, 0.94, 0.94),
        rgb(0.09, 0.09, 0.10)
    )
    static let textSecondary = dynamic(
        rgb(0.65, 0.65, 0.68),
        rgb(0.45, 0.45, 0.48)
    )

    /// Subtle structural rule used between major regions and around fields.
    static let hairline = dynamic(
        rgb(1, 1, 1, 0.10),
        rgb(0, 0, 0, 0.08)
    )
    /// Overlay scrim. Black at 0.35 in dark mode, 0.25 in light mode.
    static let scrim = dynamic(
        rgb(0, 0, 0, 0.35),
        rgb(0, 0, 0, 0.25)
    )
}

/// Reads `@AppStorage(PrefKey.theme)` and applies `.preferredColorScheme`,
/// driving BrandColors' dynamic NSColor to re-resolve on appearance change.
struct ThemeApplier<Content: View>: View {
    @AppStorage(PrefKey.theme) private var themeRaw: String = AppTheme.system.rawValue
    @AppStorage(PrefKey.language) private var languageRaw = AppLanguage.system.rawValue
    @ViewBuilder var content: () -> Content

    var body: some View {
        let scheme = AppTheme(rawValue: themeRaw)?.effectiveColorScheme
        content()
            .musesControls()
            .preferredColorScheme(scheme)
            .environment(\.locale, Locale(identifier: L10n.resolvedLanguage(preference: languageRaw)))
            .onChange(of: languageRaw, initial: true) { _, value in
                LanguagePreferences.shared.update(value)
            }
    }
}
