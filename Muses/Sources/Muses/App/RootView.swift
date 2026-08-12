import SwiftUI

struct RootView: View {
    @Environment(LibraryService.self) private var library
    @Environment(PlaylistService.self) private var playlistService
    @State private var section: SidebarSection = .home
    @State private var selectedAlbum: Album?
    @State private var selectedPlaylist: Playlist?
    @State private var selectedArtist: String?
    @State private var showImport = false
    @State private var showNowPlaying = false
    @State private var showQueue = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $section)
        } detail: {
            if let album = selectedAlbum {
                AlbumDetailView(album: album, selection: $selectedAlbum)
            } else if let artist = selectedArtist {
                ArtistDetailView(artistName: artist, selection: $selectedArtist,
                                 selectedAlbum: $selectedAlbum)
            } else if let playlist = selectedPlaylist {
                PlaylistDetailView(playlist: playlist, selectedPlaylist: $selectedPlaylist)
            } else {
                switch section {
                case .home, .albums:
                    LibraryView(selection: $section, selectedAlbum: $selectedAlbum)
                case .artists:
                    ArtistsView(selectedArtist: $selectedArtist)
                case .songs:
                    SongsListView()
                case .liked:
                    LikedView()
                case .playlists:
                    PlaylistsView(selectedPlaylist: $selectedPlaylist)
                case .youtubeImports:
                    YouTubeImportsView()
                case .youtubeSearch:
                    YouTubeSearchView()
                case .settings:
                    SettingsView()
                }
            }
        }
        .sheet(isPresented: $showImport) {
            ImportSheet()
                .environment(library)
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
        .animation(.easeInOut(duration: 0.25), value: showNowPlaying)
        .animation(.easeInOut(duration: 0.25), value: showQueue)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { showImport = true } label: { Image(systemName: "plus") }
            }
        }
    }
}

enum SidebarSection: Hashable { case home, albums, artists, songs, liked, playlists, youtubeImports, youtubeSearch, settings }

enum BrandColors {
    /// 动态主题色:深色沿用原值,浅色用浅色调色板。
    /// 用 `NSColor(name:dynamicProvider:)` 让 142 处调用零改动地随外观切换。
    private static func dynamic(_ dark: NSColor, _ light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { (appearance: NSAppearance) -> NSColor in
            appearance.name == NSAppearance.Name.darkAqua ? dark : light
        })
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1.0) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    static let background = dynamic(
        rgb(0.055, 0.055, 0.07),
        rgb(0.97, 0.97, 0.96)
    )
    static let surface = dynamic(
        rgb(0.094, 0.094, 0.125),
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

    /// 细分隔线/描边。深色 white 0.08,浅色 black 0.12。
    static let hairline = dynamic(
        rgb(1, 1, 1, 0.08),
        rgb(0, 0, 0, 0.12)
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
