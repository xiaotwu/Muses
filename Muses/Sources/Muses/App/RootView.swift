import SwiftUI

struct RootView: View {
    @Environment(LibraryService.self) private var library
    @Environment(PlaylistService.self) private var playlistService
    @Environment(SessionService.self) private var sessions
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
    @State private var showQueue = false
    @State private var showSearch = false
    @State private var showSettings = false
    @State private var showAbout = false
    @State private var showFocus = false
    @State private var showAudioInfo = false
    /// 由 Profile 弹出菜单设置,用于直接跳转到指定 Settings 分类(如 YouTube 登录)。
    @State private var initialSettingsCategory: SettingsCategory? = nil
    @AppStorage(PrefKey.language) private var language = "system"

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $section,
                        showSettings: $showSettings,
                        showAbout: $showAbout,
                        initialSettingsCategory: $initialSettingsCategory)
        } detail: {
            Group {
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
                        // Search 触发 GlobalSearchView overlay
                        EmptyView()
                            .onAppear { showSearch = true; section = .home }
                    case .pins:
                        PinsView(selection: $section, selectedAlbum: $selectedAlbum,
                                 selectedPlaylist: $selectedPlaylist)
                    case .recently:
                        RecentlyView(selection: $section, selectedAlbum: $selectedAlbum)
                    case .albums:
                        LibraryView(selection: $section, selectedAlbum: $selectedAlbum,
                                     selectedBrowsableAlbum: $selectedBrowsableAlbum)
                    case .artists:
                        ArtistsView(selectedArtist: $selectedArtist,
                                    selectedBrowsableArtist: $selectedBrowsableArtist)
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
            .safeAreaInset(edge: .bottom, spacing: 8) {
                PlayerBar(onArtworkTap: { showNowPlaying = true },
                          onQueueTap: { showQueue = true })
                    .padding(.horizontal, 8)
            }
            .background(BrandColors.background)
        }
        // P4 — 根级 tint:消除系统默认蓝色控件,统一为纯黑白主题(magenta=白/黑)。
        // 作用于所有未显式 tint 的按钮/开关/滑块/链接,符合 issue #5「蓝色 UI」根治。
        .tint(BrandColors.magenta)
        .sheet(isPresented: $showImport) {
            ImportSheet()
                .environment(library)
        }
        .sheet(isPresented: $showYouTubeLink) {
            AddYouTubeLinkSheet()
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            showAbout = false
            initialSettingsCategory = nil
        }) {
            SettingsSheet(initialCategory: initialSettingsCategory ?? (showAbout ? .about : nil))
        }
        .overlay(alignment: .trailing) {
            if showQueue {
                QueueDrawerView(isPresented: $showQueue)
            }
        }
        .overlay {
            if showNowPlaying {
                NowPlayingView(isPresented: $showNowPlaying,
                               onShowQueue: { showQueue = true })
                    .transition(.opacity)
            }
        }
        .overlay {
            if showSearch {
                GlobalSearchView(isPresented: $showSearch)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showNowPlaying)
        .animation(.easeInOut(duration: 0.25), value: showQueue)
        .animation(.easeInOut(duration: 0.2), value: showSearch)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await library.importURLs(urls) }
            return true
        }
        .onAppear {
            DispatchQueue.main.async {
                NSApp.windows.first?.setFrameAutosaveName("MusesMainWindow")
            }
        }
        // Phase 18:启动恢复对话框——绝不静默替换用户队列,必须显式「继续 / 重新开始」。
        .alert(tr("Continue previous session?", "继续上次的收听会话?"),
               isPresented: Binding(
                get: { sessions.pendingRestore != nil },
                set: { if !$0 { sessions.clearPendingRestore() } })) {
            Button(tr("Continue", "继续")) { sessions.continuePendingSession() }
            Button(tr("Start Fresh", "重新开始"), role: .destructive) {
                sessions.discardPendingSession()
            }
        } message: {
            if let offer = sessions.pendingRestore {
                Text(offer.displayText)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .musesToggleQueue)) { _ in
            showQueue.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .musesFocusSearch)) { _ in
            showSearch.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .musesNavigateArtist)) { note in
            if let artist = note.object as? Artist {
                selectedArtist = artist
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .musesNavigateAlbum)) { note in
            if let album = note.object as? Album {
                selectedAlbum = album
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .musesSelectPlaylist)) { note in
            if let playlist = note.object as? Playlist {
                selectedPlaylist = playlist
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .musesNavigateYouTubeImport)) { note in
            if let ytImport = note.object as? YouTubeImport {
                selectedYouTubeImport = ytImport
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .musesCloseYouTubeAlbum)) { _ in
            selectedYouTubeImport = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .musesToggleFocusMode)) { _ in
            showFocus.toggle()
        }
        .sheet(isPresented: $showFocus) {
            FocusView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .musesToggleAudioInfo)) { _ in
            showAudioInfo.toggle()
        }
        .sheet(isPresented: $showAudioInfo) {
            AudioInfoPanel()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                AddMusicMenu(showLocalFolder: $showImport, showYouTubeLink: $showYouTubeLink)
            }
        }
        .id(language)
    }
}

enum SidebarSection: String, Hashable, CaseIterable {
    case search, home, new
    case pins, recently, artists, albums, songs  // Library subsections
    case playlists
    case history  // Phase 17: Smart Listening History
    case inbox    // Phase 20: Music Inbox
}

extension Notification.Name {
    static let musesToggleQueue = Notification.Name("muses.toggleQueue")
    static let musesFocusSearch = Notification.Name("muses.focusSearch")
    static let musesNavigateYouTubeImport = Notification.Name("muses.navigateYouTubeImport")
    static let musesCloseYouTubeAlbum = Notification.Name("muses.closeYouTubeAlbum")
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

    /// 纯黑背景(Apple Music 深色风格)。
    static let background = dynamic(
        rgb(0, 0, 0),
        rgb(0.97, 0.97, 0.96)
    )
    /// 卡片/表面色:略高于纯黑,用于卡片背景。
    static let surface = dynamic(
        rgb(0.15, 0.15, 0.17),
        rgb(0.92, 0.92, 0.94)
    )
    /// 纯黑白主题:副颜色为白色(深色)或黑色(浅色)。
    static let magenta = dynamic(
        rgb(1, 1, 1),
        rgb(0, 0, 0)
    )
    static let cyan = dynamic(
        rgb(1, 1, 1),
        rgb(0, 0, 0)
    )
    static let green = dynamic(
        rgb(1, 1, 1),
        rgb(0, 0, 0)
    )
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
