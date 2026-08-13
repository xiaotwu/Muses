import SwiftUI

struct RootView: View {
    @Environment(LibraryService.self) private var library
    @Environment(PlaylistService.self) private var playlistService
    @State private var section: SidebarSection = .home
    @State private var selectedAlbum: Album?
    @State private var selectedPlaylist: Playlist?
    @State private var selectedArtist: Artist?
    @State private var showImport = false
    @State private var showNowPlaying = false
    @State private var showQueue = false
    @State private var showSearch = false
    @State private var showSettings = false
    @State private var showAbout = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $section,
                        showSettings: $showSettings,
                        showAbout: $showAbout)
        } detail: {
            if let album = selectedAlbum {
                AlbumDetailView(album: album, selection: $selectedAlbum)
            } else if let artist = selectedArtist {
                ArtistDetailView(artist: artist, selection: $selectedArtist,
                                 selectedAlbum: $selectedAlbum)
            } else if let playlist = selectedPlaylist {
                PlaylistDetailView(playlist: playlist, selectedPlaylist: $selectedPlaylist)
            } else {
                switch section {
                case .home:
                    HomeView(selection: $section, selectedAlbum: $selectedAlbum)
                case .new:
                    NewView()
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
                    LibraryView(selection: $section, selectedAlbum: $selectedAlbum)
                case .artists:
                    ArtistsView(selectedArtist: $selectedArtist)
                case .songs:
                    SongsListView()
                case .youtubeMusic:
                    YouTubeMusicView()
                case .playlists:
                    PlaylistsView(selectedPlaylist: $selectedPlaylist)
                }
            }
        }
        .sheet(isPresented: $showImport) {
            ImportSheet()
                .environment(library)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
        }
        .sheet(isPresented: $showAbout) {
            AboutSheet()
        }
        .background(BrandColors.background)
        .overlay(alignment: .bottom) {
            PlayerBar(onArtworkTap: { showNowPlaying = true },
                      onQueueTap: { showQueue = true })
        }
        .overlay(alignment: .trailing) {
            if showQueue {
                QueueDrawerView(isPresented: $showQueue)
            }
        }
        .overlay {
            if showNowPlaying {
                NowPlayingView(isPresented: $showNowPlaying)
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
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { showImport = true } label: { Image(systemName: "plus") }
            }
        }
    }
}

enum SidebarSection: String, Hashable, CaseIterable {
    case search, home, new
    case pins, recently, artists, albums, songs  // Library subsections
    case youtubeMusic
    case playlists
}

extension Notification.Name {
    static let musesToggleQueue = Notification.Name("muses.toggleQueue")
    static let musesFocusSearch = Notification.Name("muses.focusSearch")
}

enum BrandColors {
    /// 动态主题色:深色采用纯黑(Apple Music 风格),浅色用浅色调色板。
    /// 用 `NSColor(name:dynamicProvider:)` 让所有调用零改动地随外观切换。
    private static func dynamic(_ dark: NSColor, _ light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { (appearance: NSAppearance) -> NSColor in
            appearance.name == NSAppearance.Name.darkAqua ? dark : light
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
        rgb(0.08, 0.08, 0.10),
        rgb(0.92, 0.92, 0.94)
    )
    static let magenta = dynamic(
        rgb(0.94, 0.56, 0.94),
        rgb(0.82, 0.40, 0.82)
    )
    static let cyan = dynamic(
        rgb(0.09, 0.66, 0.94),
        rgb(0.05, 0.55, 0.85)
    )
    static let green = dynamic(
        rgb(0.09, 0.66, 0.09),
        rgb(0.06, 0.58, 0.22)
    )
    static let textPrimary = dynamic(
        rgb(0.94, 0.94, 0.94),
        rgb(0.09, 0.09, 0.10)
    )
    static let textSecondary = dynamic(
        rgb(0.53, 0.53, 0.57),
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
