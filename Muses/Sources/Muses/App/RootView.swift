import SwiftUI
import AppKit

struct RootView: View {
    @Environment(LibraryService.self) private var library
    @Environment(PlaylistService.self) private var playlistService
    @Environment(SessionService.self) private var sessions
    @Environment(PlaybackService.self) private var playback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var artworkWorld
    @State private var coverSlot: Anchor<CGRect>?
    @State private var section: SidebarSection = .home
    @State private var selectedAlbum: Album?
    @State private var selectedPlaylist: Playlist?
    @State private var selectedArtist: Artist?
    @State private var selectedYouTubeImport: YouTubeImport?
    // P3 — 派生(YouTube-derived)浏览条目详情;本地条目仍走 selectedAlbum/selectedArtist。
    @State private var selectedBrowsableAlbum: BrowsableAlbum?
    @State private var selectedBrowsableArtist: BrowsableArtist?
    @State private var showImport = false
    @State private var showYouTubeLink = false
    @State private var showNowPlaying = false
    /// Keeps `LiveCoverHost` mounted through the close morph so PlayerBar still has a pair.
    @State private var liveCoverHostRetained = false
    @State private var nowPlayingShowLyrics = true
    @State private var windowWidth: CGFloat = 1440
    @State private var showQueue = false
    @State private var showLyricsDrawer = false
    @State private var showSearch = false
    @State private var showSettings = false
    @State private var showAbout = false
    @State private var showFocus = false
    @State private var showAudioInfo = false
    /// 由 Profile 弹出菜单设置,用于直接跳转到指定 Settings 分类(如 YouTube 登录)。
    @State private var initialSettingsCategory: SettingsCategory? = nil
    @AppStorage(PrefKey.language) private var language = "system"
    @AppStorage(PrefKey.nowPlayingLyricsMode) private var lyricsModeRaw: String = NowPlayingLyricsMode.inline.rawValue
    @Environment(\.libraryStoreFallback) private var libraryStoreFallback
    @State private var showStoreFallbackAlert = false
    @State private var showYouTubeVideo = false
    @AppStorage(PrefKey.sidebarCollapsed) private var sidebarCollapsed = false
    @AppStorage(PrefKey.nowPlayingMode) private var nowPlayingModeRaw: String = NowPlayingMode.cover.rawValue

    private var lyricsFullscreen: Bool {
        nowPlayingShowLyrics && (NowPlayingLyricsMode(rawValue: lyricsModeRaw) ?? .inline) != .inline
    }

    private var skipArtworkMorph: Bool {
        reduceMotion
            || lyricsFullscreen
            || playback.state.track?.id == nil
            || windowWidth < 960
    }

    var body: some View {
        notificationWired
            .id(language)
    }

    private var notificationWired: some View {
        navigationWired
            .onChange(of: showSettings) { _, open in
                if !open {
                    showAbout = false
                    initialSettingsCategory = nil
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let text = urls.map(\.absoluteString).joined(separator: "\n")
                if text.contains("youtu") {
                    showYouTubeLink = true
                }
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
            .onReceive(NotificationCenter.default.publisher(for: .musesFocusSearch)) { _ in
                showSearch.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .musesOpenSettings)) { note in
                if let category = note.object as? SettingsCategory {
                    initialSettingsCategory = category
                }
                showSettings = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .musesToggleSidebar)) { _ in
                sidebarCollapsed.toggle()
            }
            .onChange(of: section) { _, new in
                applySidebarSectionChange(new)
            }
            .onReceive(NotificationCenter.default.publisher(for: .musesToggleFocusMode)) { _ in
                showFocus.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .musesToggleAudioInfo)) { _ in
                showAudioInfo.toggle()
            }
    }

    private var navigationWired: some View {
        sheetHost
            .onReceive(NotificationCenter.default.publisher(for: .musesNavigateArtist)) { note in
                if let artist = note.object as? Artist { selectedArtist = artist }
            }
            .onReceive(NotificationCenter.default.publisher(for: .musesNavigateAlbum)) { note in
                if let album = note.object as? Album { selectedAlbum = album }
            }
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
    }

    private var sheetHost: some View {
        alertHost
            .sheet(isPresented: $showFocus) {
                FocusView()
                    .tint(BrandColors.magenta)
            }
            .sheet(isPresented: $showAudioInfo) {
                AudioInfoPanel()
                    .tint(BrandColors.magenta)
            }
    }

    private var sessionRestorePresented: Binding<Bool> {
        Binding(
            get: { sessions.pendingRestore != nil },
            set: { if !$0 { sessions.clearPendingRestore() } }
        )
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
            .alert(tr("Continue previous session?", "继续上次的收听会话?"),
                   isPresented: sessionRestorePresented) {
                Button(tr("Continue", "继续")) { sessions.continuePendingSession() }
                Button(tr("Start Fresh", "重新开始"), role: .destructive) {
                    sessions.discardPendingSession()
                }
            } message: {
                if let offer = sessions.pendingRestore {
                    Text(offer.displayText)
                }
            }
    }

    private func handleAppear() {
        if libraryStoreFallback { showStoreFallbackAlert = true }
        DispatchQueue.main.async {
            MusesSingleInstance.orderFrontMainWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            MusesSingleInstance.orderFrontMainWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            MusesSingleInstance.setWindowToolbarVisible(false)
            for window in NSApp.windows {
                MusesSingleInstance.hideSystemSidebarButtons(in: window)
            }
        }
    }

    private func rehideSidebarToggle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            for window in NSApp.windows {
                MusesSingleInstance.hideSystemSidebarButtons(in: window)
            }
        }
    }

    /// Sidebar items must replace pushed album/artist/playlist detail. Playlist
    /// rows set `section` to `.playlists` *after* selecting a playlist, so that
    /// destination keeps playlist / YouTube-import context.
    private func applySidebarSectionChange(_ new: SidebarSection) {
        selectedAlbum = nil
        selectedBrowsableAlbum = nil
        selectedArtist = nil
        selectedBrowsableArtist = nil
        if SidebarDetailClearPolicy.policy(for: new) == .clearAll {
            selectedPlaylist = nil
            selectedYouTubeImport = nil
        }
    }

    private let chromeTop: CGFloat = 52
    private let chromeSide: CGFloat = 0
    private let chromeBottom: CGFloat = PlayerDockMetrics.height
    private var showsLibrarySidebar: Bool { section.isLibrary && !sidebarCollapsed }

    private var splitView: some View {
        VStack(spacing: 0) {
            AppTopBar(section: $section, showSettings: $showSettings)
            HStack(spacing: 0) {
                if showsLibrarySidebar {
                    SidebarView(selection: $section,
                                showSettings: $showSettings,
                                showAbout: $showAbout,
                                initialSettingsCategory: $initialSettingsCategory,
                                selectedPlaylist: $selectedPlaylist,
                                selectedYouTubeImport: $selectedYouTubeImport,
                                sidebarCollapsed: $sidebarCollapsed)
                        .frame(width: 232)
                }
                detailStack
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(BrowseBackground())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !showYouTubeVideo {
                PlayerBar(showNowPlaying: showNowPlaying,
                          skipArtworkMorph: skipArtworkMorph,
                          lyricsActive: showLyricsDrawer,
                          queueActive: showQueue,
                          onArtworkTap: { openNowPlaying() },
                          onLyricsTap: {
                              showLyricsDrawer.toggle()
                              showQueue = false
                          },
                          onQueueTap: {
                              showQueue.toggle()
                              showLyricsDrawer = false
                          },
                          onVideoTap: { showYouTubeVideo = true })
            }
        }
        .background(BrandColors.background)
        .toolbar(.hidden)
        .tint(BrandColors.magenta)
        .animation(MusesMotion.drawerAnimation(reduceMotion: reduceMotion), value: showsLibrarySidebar)
        .focusEffectDisabled()
    }

    private func openNowPlaying() {
        showQueue = false
        showLyricsDrawer = false
        showNowPlaying = true
    }

    @ViewBuilder
    private var detailStack: some View {
        if let album = selectedAlbum {
            AlbumDetailView(album: album, selection: $selectedAlbum)
        } else if let browsableAlbum = selectedBrowsableAlbum {
            DerivedAlbumDetailView(browsable: browsableAlbum, selection: $selectedBrowsableAlbum)
        } else if let artist = selectedArtist {
            ArtistDetailView(artist: artist, selection: $selectedArtist,
                             selectedAlbum: $selectedAlbum)
        } else if let browsableArtist = selectedBrowsableArtist {
            DerivedArtistDetailView(browsable: browsableArtist, selection: $selectedBrowsableArtist)
        } else if let playlist = selectedPlaylist {
            PlaylistDetailView(playlist: playlist, selectedPlaylist: $selectedPlaylist)
        } else if let ytImport = selectedYouTubeImport {
            YouTubeAlbumDetailView(youTubeImport: ytImport)
        } else {
            switch section {
            case .home:
                HomeView(selection: $section, selectedAlbum: $selectedAlbum)
            case .new:
                NewView(selectedAlbum: $selectedAlbum)
            case .search:
                HomeView(selection: $section, selectedAlbum: $selectedAlbum)
            case .pins:
                RecentlyView(selection: $section, selectedAlbum: $selectedAlbum)
            case .recently:
                RecentlyView(selection: $section, selectedAlbum: $selectedAlbum)
            case .albums, .artists:
                SongsListView()
            case .songs:
                SongsListView()
            case .playlists:
                PlaylistsView(selectedPlaylist: $selectedPlaylist)
            case .history:
                HistoryView()
            case .inbox:
                InboxView()
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
                VStack(spacing: 0) {
                    Color.clear.frame(height: chromeTop)
                        .allowsHitTesting(false)
                    nowPlayingLayers
                    Color.clear.frame(height: showYouTubeVideo ? 0 : chromeBottom)
                        .allowsHitTesting(false)
                }
                .tint(BrandColors.magenta)
            }
            .overlay {
                if !showNowPlaying, showLyricsDrawer || showQueue {
                    ZStack(alignment: .trailing) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                showQueue = false
                                showLyricsDrawer = false
                            }
                        HStack(alignment: .top, spacing: 8) {
                            if showLyricsDrawer {
                                LyricsDrawerView(isPresented: $showLyricsDrawer)
                            }
                            if showQueue {
                                QueueDrawerView(isPresented: $showQueue, showsScrim: false)
                            }
                        }
                        .padding(.top, chromeTop)
                        .padding(.trailing, 12)
                        .padding(.bottom, chromeBottom + 8)
                    }
                    .tint(BrandColors.magenta)
                }
            }
            .overlay {
                if showSearch {
                    GlobalSearchView(isPresented: $showSearch,
                                      showLocalFolder: $showImport,
                                      showYouTubeLink: $showYouTubeLink)
                        .transition(.opacity)
                        .tint(BrandColors.magenta)
                }
            }
            .overlay {
                if showSettings {
                    SettingsSheet(
                        isPresented: $showSettings,
                        initialCategory: initialSettingsCategory ?? (showAbout ? .about : nil)
                    )
                    .tint(BrandColors.magenta)
                }
            }
            .overlay {
                if showYouTubeLink {
                    ZStack {
                        BrandColors.scrim
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { showYouTubeLink = false }
                        AddYouTubeLinkSheet(isPresented: $showYouTubeLink)
                    }
                    .tint(BrandColors.magenta)
                }
            }
            .animation(MusesMotion.morphAnimation(reduceMotion: reduceMotion), value: showNowPlaying)
            .animation(MusesMotion.drawerAnimation(reduceMotion: reduceMotion), value: showQueue)
            .animation(MusesMotion.overlayAnimation(reduceMotion: reduceMotion), value: showSearch)
            .animation(MusesMotion.overlayAnimation(reduceMotion: reduceMotion), value: showYouTubeVideo)
            .animation(MusesMotion.overlayAnimation(reduceMotion: reduceMotion), value: showSettings)
            .overlay {
                if showYouTubeVideo, let videoId = playback.state.track?.youTubeId {
                    YouTubeVideoOverlay(videoId: videoId, isPresented: $showYouTubeVideo)
                        .tint(BrandColors.magenta)
                }
            }
            .onChange(of: showNowPlaying) { _, open in
                if !open { nowPlayingShowLyrics = true }
                if open {
                    showQueue = false
                    showLyricsDrawer = false
                    liveCoverHostRetained = !skipArtworkMorph
                } else if liveCoverHostRetained {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(MusesMotion.nowPlayingMorph * 1_000_000_000))
                        if !showNowPlaying {
                            liveCoverHostRetained = false
                        }
                    }
                }
                MusesSingleInstance.setWindowToolbarVisible(false)
            }
            .onChange(of: showYouTubeVideo) { _, _ in
                MusesSingleInstance.setWindowToolbarVisible(false)
            }
            .onChange(of: section) { _, _ in rehideSidebarToggle() }
            .onChange(of: selectedAlbum?.id) { _, _ in rehideSidebarToggle() }
            .onChange(of: selectedArtist?.id) { _, _ in rehideSidebarToggle() }
            .onChange(of: selectedPlaylist?.id) { _, _ in rehideSidebarToggle() }
            .onChange(of: selectedYouTubeImport?.id) { _, _ in rehideSidebarToggle() }
    }

    /// Back → middle → front: environment gradient, chrome, live-cover host.
    private var nowPlayingLayers: some View {
        GeometryReader { _ in
            ZStack {
                if showNowPlaying {
                    NowPlayingEnvironmentLayer()
                        .transition(.opacity)
                        .zIndex(0)
                    NowPlayingView(isPresented: $showNowPlaying,
                                   showLyrics: $nowPlayingShowLyrics,
                                   coverHostedExternally: !skipArtworkMorph)
                        .transition(.opacity)
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
        .allowsHitTesting(showNowPlaying)
    }

    @ViewBuilder
    private func liveCoverHost(proxy: GeometryProxy, anchor: Anchor<CGRect>?) -> some View {
        if (showNowPlaying || liveCoverHostRetained), !skipArtworkMorph,
           let trackID = playback.state.track?.id {
            let host = LiveCoverHost(
                source: ArtworkSource.resolve(for: playback.state.track),
                trackID: trackID,
                namespace: artworkWorld,
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
            } else if liveCoverHostRetained, !showNowPlaying {
                host.opacity(0)
            }
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
    case pins, recently, artists, albums, songs  // Library subsections
    case playlists
    case history  // Phase 17: Smart Listening History
    case inbox    // Phase 20: Music Inbox
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
    static let musesFocusSearch = Notification.Name("muses.focusSearch")
    static let musesNavigateYouTubeImport = Notification.Name("muses.navigateYouTubeImport")
    static let musesCloseYouTubeAlbum = Notification.Name("muses.closeYouTubeAlbum")
    static let musesShowPlaylistsOverview = Notification.Name("muses.showPlaylistsOverview")
    static let musesOpenSettings = Notification.Name("muses.openSettings")
    static let musesToggleSidebar = Notification.Name("muses.toggleSidebar")
    // Phase 24 — 桌面集成通知。
    static let musesOpenMiniPlayer = Notification.Name("muses.openMiniPlayer")
    static let musesToggleDesktopLyrics = Notification.Name("muses.toggleDesktopLyrics")
    static let musesDesktopFlagsChanged = Notification.Name("muses.desktopFlagsChanged")
    static let musesToggleFocusMode = Notification.Name("muses.toggleFocusMode")
    // Phase 26 — 音频信息面板。
    static let musesToggleAudioInfo = Notification.Name("muses.toggleAudioInfo")
}

enum BrandColors {
    /// 动态主题色:深色采用纯黑(Apple Music 风格),浅色用浅色调色板。
    /// 用 `NSColor(name:dynamicProvider:)` 让所有调用零改动地随外观切换。
    private static func dynamic(_ dark: NSColor, _ light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { (appearance: NSAppearance) -> NSColor in
            // `appearance.name == .darkAqua` 仅匹配标准深色外观,会漏掉高对比深色
            // (.accessibilityHighContrastDarkAqua) 与 vibrantDark 等变体,导致在
            // 这些变体下误用浅色分支(浅色文字近乎黑色,深色背景下不可读)。
            // `bestMatch` 在外观层级中返回首个命中的标准外观,可覆盖所有深色变体。
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
    /// 卡片/表面色:略高于页面底。
    static let surface = dynamic(
        rgb(0.15, 0.15, 0.17),
        rgb(0.92, 0.92, 0.94)
    )
    /// Apple Music `--keyColor` #FA586A (play, scrubber, selected row, active lyric).
    static let magenta = dynamic(
        rgb(AppleMusicTokens.keyColorRGB.r,
            AppleMusicTokens.keyColorRGB.g,
            AppleMusicTokens.keyColorRGB.b),
        rgb(AppleMusicTokens.keyColorRGB.r,
            AppleMusicTokens.keyColorRGB.g,
            AppleMusicTokens.keyColorRGB.b)
    )
    static let cyan = magenta
    static let green = magenta
    static let textPrimary = dynamic(
        rgb(0.94, 0.94, 0.94),
        rgb(0.09, 0.09, 0.10)
    )
    static let textSecondary = dynamic(
        rgb(0.65, 0.65, 0.68),
        rgb(0.45, 0.45, 0.48)
    )

    /// 分隔线:透明(取消所有分割线,实现整体统一)。
    static let hairline = dynamic(
        rgb(1, 1, 1, 0),
        rgb(0, 0, 0, 0)
    )
    /// 遮罩 scrim。深色 black 0.35,浅色 black 0.25。
    static let scrim = dynamic(
        rgb(0, 0, 0, 0.35),
        rgb(0, 0, 0, 0.25)
    )
}

/// 读 `@AppStorage(PrefKey.theme)` 并施加 `.preferredColorScheme`,
/// 驱动 BrandColors 动态 NSColor 在外观切换时重解析。
struct ThemeApplier<Content: View>: View {
    @AppStorage(PrefKey.theme) private var themeRaw: String = AppTheme.dark.rawValue
    @ViewBuilder var content: () -> Content

    var body: some View {
        let scheme = AppTheme(rawValue: themeRaw)?.effectiveColorScheme
        content().preferredColorScheme(scheme)
    }
}
