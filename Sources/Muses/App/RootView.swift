import SwiftUI
import AppKit

struct RootView: View {
    @Environment(LibraryService.self) private var library
    @Environment(PlaylistService.self) private var playlistService
    @Environment(PlaybackService.self) private var playback
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
    @State private var showSettings = false
    @State private var showAbout = false
    @State private var showFocus = false
    @State private var showAudioInfo = false
    /// Set by the Profile popover menu, to jump straight to a given Settings category (e.g. YouTube sign-in).
    @State private var initialSettingsCategory: SettingsCategory? = nil
    @AppStorage(PrefKey.language) private var language = "system"
    @AppStorage(PrefKey.nowPlayingLyricsMode) private var lyricsModeRaw: String = NowPlayingLyricsMode.inline.rawValue
    @Environment(\.libraryStoreFallback) private var libraryStoreFallback
    @State private var showStoreFallbackAlert = false
    @State private var showYouTubeVideo = false
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
                if open {
                    dismissTransientOverlaysForSettings()
                } else {
                    showAbout = false
                    initialSettingsCategory = nil
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !showSettings else { return false }
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
                guard !showSettings else { return }
                if showNowPlaying {
                    showNowPlaying = false
                }
                showQueue.toggle()
                if showQueue { showLyricsDrawer = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: .musesFocusSearch)) { _ in
                showSettings = false
                openWindow(id: SearchWindowPolicy.sceneID)
            }
            .onReceive(NotificationCenter.default.publisher(for: .musesOpenSettings)) { note in
                if let category = note.object as? SettingsCategory {
                    initialSettingsCategory = category
                }
                showSettings = true
            }
            .onChange(of: section) { _, new in
                showSettings = false
                applySidebarSectionChange(new)
            }
            .onReceive(NotificationCenter.default.publisher(for: .musesToggleFocusMode)) { _ in
                guard !showSettings else { return }
                showFocus.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .musesToggleAudioInfo)) { _ in
                guard !showSettings else { return }
                showAudioInfo.toggle()
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
                showSettings = false
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

    private func handleAppear() {
        if libraryStoreFallback { showStoreFallbackAlert = true }
        DispatchQueue.main.async {
            MusesSingleInstance.orderFrontMainWindow()
        }
    }

    /// Settings is modal within the main window. Close transient chrome instead
    /// of leaving hidden keyboard/VoiceOver targets behind the glass panel.
    private func dismissTransientOverlaysForSettings() {
        guard SettingsChromePolicy.dismissesTransientOverlaysOnPresentation else { return }
        showQueue = false
        showLyricsDrawer = false
        showYouTubeVideo = false
        showYouTubeLink = false
        showFocus = false
        showAudioInfo = false
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
                        showSettings: $showSettings,
                        showAbout: $showAbout,
                        initialSettingsCategory: $initialSettingsCategory,
                        selectedPlaylist: $selectedPlaylist,
                        selectedYouTubeImport: $selectedYouTubeImport)
            ZStack(alignment: .bottom) {
                detailStack
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(BrowseBackground())
                if !showYouTubeVideo, !showSettings,
                   !(showNowPlaying && NowPlayingChromePolicy.hidesDock) {
                    PlayerBar(lyricsActive: showLyricsDrawer,
                              queueActive: showQueue,
                              onArtworkTap: { openNowPlaying() },
                              onLyricsTap: { handleDockLyrics() },
                              onQueueTap: {
                                  showQueue.toggle()
                                  showLyricsDrawer = false
                              },
                              onVideoTap: { showYouTubeVideo = true })
                        .padding(.horizontal, AppleMusicTokens.playerHorizontalMargin)
                        .padding(.bottom, AppleMusicTokens.playerBottomMargin)
                }
            }
        }
        .background(BrandColors.background)
        .background {
            MainWindowConfigurator()
                .frame(width: 0, height: 0)
        }
        .ignoresSafeArea(edges: [.top, .bottom, .leading])
        .tint(BrandColors.magenta)
        // The centered Settings overlay owns pointer/trackpad input while it is
        // visible. Disabling the browse tree also suspends the deck's AppKit
        // scroll monitor, which otherwise sees coordinates through overlays.
        .disabled(!SettingsChromePolicy.allowsBrowseInteraction(isPresented: showSettings))
        .accessibilityHidden(showNowPlaying || showSettings)
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
            nowPlayingShowLyrics.toggle()
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
            case .playlists:
                PlaylistsView(selectedPlaylist: $selectedPlaylist)
            case .history:
                HistoryView()
            case .inbox:
                if LibraryChromePolicy.showsInbox {
                    InboxView()
                } else {
                    SongsListView()
                }
            }
        }
    }

    private func continuityChrome<Content: View>(_ content: Content) -> some View {
        content
            .ignoresSafeArea(edges: .top)
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
                        .tint(BrandColors.magenta)
                        .disabled(!SettingsChromePolicy.allowsUnderlyingInteraction(
                            isPresented: showSettings
                        ))
                        .accessibilityHidden(showSettings)
                } else {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: chromeTop)
                            .allowsHitTesting(false)
                        nowPlayingLayers
                            .disabled(!SettingsChromePolicy.allowsUnderlyingInteraction(
                                isPresented: showSettings
                            ))
                            .accessibilityHidden(showSettings)
                        Color.clear.frame(height: showYouTubeVideo ? 0 : chromeBottom)
                            .allowsHitTesting(false)
                    }
                    .tint(BrandColors.magenta)
                }
            }
            .overlay {
                if !showSettings, !showNowPlaying, showLyricsDrawer || showQueue {
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
                        .padding(.bottom, chromeBottom)
                    }
                    .tint(BrandColors.magenta)
                    .accessibilityHidden(showSettings)
                }
            }
            .overlay {
                if SettingsChromePolicy.presentsAsFloatingGlass, showSettings {
                    ZStack {
                        BrandColors.scrim
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { showSettings = false }
                        SettingsSheet(
                            isPresented: $showSettings,
                            initialCategory: initialSettingsCategory ?? (showAbout ? .about : nil)
                        )
                        .frame(width: 520, height: 560)
                        .background(
                            BrandColors.surface.opacity(0.90),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .musesGlass(cornerRadius: 18)
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(BrandColors.hairline, lineWidth: 1)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .zIndex(50)
                    .tint(BrandColors.magenta)
                }
            }
            .overlay {
                if !showSettings, showYouTubeLink {
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
            .animation(MusesMotion.drawerAnimation(reduceMotion: reduceMotion), value: showQueue)
            .animation(MusesMotion.overlayAnimation(reduceMotion: reduceMotion), value: showYouTubeVideo)
            .animation(MusesMotion.overlayAnimation(reduceMotion: reduceMotion), value: showSettings)
            .overlay {
                if !showSettings, showYouTubeVideo,
                   let videoId = playback.state.track?.youTubeId {
                    YouTubeVideoOverlay(videoId: videoId, isPresented: $showYouTubeVideo)
                        .tint(BrandColors.magenta)
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
                                   settingsPresented: $showSettings,
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
            isPresented: showNowPlaying,
            settingsPresented: showSettings
        ))
        .accessibilityHidden(!NowPlayingPresentationPolicy.isAccessibilityVisible(
            isPresented: showNowPlaying,
            settingsPresented: showSettings
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
            guard !showNowPlaying, !showSettings else { return }
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
    case artists, albums, songs  // Library subsections
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
    static let musesNavigateFromSearch = Notification.Name("muses.navigateFromSearch")
    static let musesNavigateYouTubeImport = Notification.Name("muses.navigateYouTubeImport")
    static let musesCloseYouTubeAlbum = Notification.Name("muses.closeYouTubeAlbum")
    static let musesShowPlaylistsOverview = Notification.Name("muses.showPlaylistsOverview")
    static let musesOpenSettings = Notification.Name("muses.openSettings")
    // Desktop integration notifications (mini player, desktop lyrics, focus mode).
    static let musesOpenMiniPlayer = Notification.Name("muses.openMiniPlayer")
    static let musesToggleDesktopLyrics = Notification.Name("muses.toggleDesktopLyrics")
    static let musesDesktopFlagsChanged = Notification.Name("muses.desktopFlagsChanged")
    static let musesToggleFocusMode = Notification.Name("muses.toggleFocusMode")
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
    /// Apple Music `--keyColor` #FA586A (play, scrubber, selected row, active lyric).
    static let magenta = dynamic(
        rgb(AppleMusicTokens.keyColorRGB.r,
            AppleMusicTokens.keyColorRGB.g,
            AppleMusicTokens.keyColorRGB.b),
        rgb(AppleMusicTokens.keyColorRGB.r,
            AppleMusicTokens.keyColorRGB.g,
            AppleMusicTokens.keyColorRGB.b)
    )
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
    @AppStorage(PrefKey.theme) private var themeRaw: String = AppTheme.dark.rawValue
    @ViewBuilder var content: () -> Content

    var body: some View {
        let scheme = AppTheme(rawValue: themeRaw)?.effectiveColorScheme
        content().preferredColorScheme(scheme)
    }
}
