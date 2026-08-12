import SwiftUI

struct RootView: View {
    @Environment(LibraryService.self) private var library
    @State private var section: SidebarSection = .home
    @State private var selectedAlbum: Album?
    @State private var showImport = false
    @State private var showNowPlaying = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $section)
        } detail: {
            if let album = selectedAlbum {
                AlbumDetailView(album: album, selection: $selectedAlbum)
            } else {
                switch section {
                case .home, .albums:
                    LibraryView(selection: $section, selectedAlbum: $selectedAlbum)
                case .songs:
                    SongsListView()
                case .liked:
                    LikedView()
                case .settings:
                    SettingsPlaceholderView()
                }
            }
        }
        .sheet(isPresented: $showImport) {
            ImportSheet()
                .environment(library)
        }
        .background(BrandColors.background)
        .overlay(alignment: .bottom) {
            PlayerBar(onArtworkTap: { showNowPlaying = true })
        }
        .overlay {
            if showNowPlaying {
                NowPlayingView(isPresented: $showNowPlaying)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showNowPlaying)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { showImport = true } label: { Image(systemName: "plus") }
            }
        }
    }
}

enum SidebarSection: Hashable { case home, albums, songs, liked, settings }

enum BrandColors {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.07)
    static let surface = Color(red: 0.094, green: 0.094, blue: 0.125)
    static let magenta = Color(red: 0.94, green: 0.56, blue: 0.94)
    static let cyan = Color(red: 0.09, green: 0.66, blue: 0.94)
    static let green = Color(red: 0.09, green: 0.66, blue: 0.09)
    static let textPrimary = Color(red: 0.94, green: 0.94, blue: 0.94)
    static let textSecondary = Color(red: 0.53, green: 0.53, blue: 0.57)
}
