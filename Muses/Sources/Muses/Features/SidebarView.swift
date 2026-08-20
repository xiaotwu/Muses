import SwiftUI
import AppKit
import SwiftData

/// Library pane: Recently / Songs / Playlists / History / Inbox + playlist rows.
/// Always mounted unless the user collapsed it.
struct SidebarView: View {
    @Binding var selection: SidebarSection
    @Binding var showSettings: Bool
    @Binding var showAbout: Bool
    @Binding var initialSettingsCategory: SettingsCategory?
    @Binding var selectedPlaylist: Playlist?
    @Binding var selectedYouTubeImport: YouTubeImport?
    @Binding var sidebarCollapsed: Bool
    @Environment(PlaylistService.self) private var playlistService
    @Environment(YouTubeImportService.self) private var importService
    @State private var playlists: [Playlist] = []
    @Query(sort: \YouTubeImport.importedAt, order: .reverse) private var ytImports: [YouTubeImport]
    @State private var showCreatePlaylist = false

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section(tr("Library", "资料库")) {
                    libraryRow("clock", tr("Recently", "最近"), .recently)
                    libraryRow("music.note", tr("Songs", "歌曲"), .songs)
                    libraryRow("clock.arrow.circlepath", tr("History", "历史记录"), .history)
                    libraryRow("tray", tr("Inbox", "收件箱"), .inbox)
                }

                Section(tr("Playlists", "歌单")) {
                    Label {
                        Text(tr("All Playlists", "全部歌单"))
                    } icon: {
                        ChromeGlyph(systemName: "music.note.list",
                                    selected: selection == .playlists && selectedPlaylist == nil && selectedYouTubeImport == nil)
                    }
                    .tag(SidebarSection.playlists)
                    .simultaneousGesture(TapGesture().onEnded {
                        selectedPlaylist = nil
                        selectedYouTubeImport = nil
                        NotificationCenter.default.post(name: .musesShowPlaylistsOverview, object: nil)
                    })
                    ForEach(orderedItems) { item in
                        PlaylistSidebarRow(
                            item: item,
                            isSelected: isPlaylistSelected(item)
                        ) { handlePlaylistTap(item) }
                        .contextMenu {
                            Button(tr("Open", "打开")) { handlePlaylistTap(item) }
                            Button(tr("Remove", "移除"), role: .destructive) {
                                removeSidebarItem(item)
                            }
                        }
                    }
                    .onMove(perform: moveSidebarItems)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .frame(width: AppleMusicTokens.sidebarWidth)
        .background(BrandColors.background)
        .sheet(isPresented: $showCreatePlaylist) {
            NewPlaylistSheet(isPresented: $showCreatePlaylist) { name in
                playlistService.create(name: name)
                refreshPlaylists()
            }
        }
        .onAppear { refreshPlaylists() }
        .onReceive(NotificationCenter.default.publisher(for: .musesPlaylistsChanged)) { _ in
            refreshPlaylists()
        }
        .onReceive(NotificationCenter.default.publisher(for: .musesSelectPlaylist)) { _ in
            selection = .playlists
        }
        .onReceive(NotificationCenter.default.publisher(for: .musesNavigateYouTubeImport)) { _ in
            selection = .playlists
        }
        .onChange(of: selection) { _, new in
            if new != .playlists {
                selectedPlaylist = nil
                selectedYouTubeImport = nil
            }
        }
    }

    private func libraryRow(_ icon: String, _ title: String, _ tag: SidebarSection) -> some View {
        Label {
            Text(title)
        } icon: {
            ChromeGlyph(systemName: icon, selected: selection == tag)
        }
        .tag(tag)
    }

    private var mergedItems: [SidebarPlaylistItem] {
        PlaylistSidebarAdapter.merged(local: playlists, youTube: ytImports)
    }

    private var orderedItems: [SidebarPlaylistItem] {
        SidebarPlaylistOrder.apply(mergedItems)
    }

    private func moveSidebarItems(from source: IndexSet, to destination: Int) {
        var ids = orderedItems.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        SidebarPlaylistOrder.save(ids)
    }

    private func removeSidebarItem(_ item: SidebarPlaylistItem) {
        switch item.origin {
        case .local:
            if let pid = item.playlistId, let pl = playlists.first(where: { $0.id == pid }) {
                playlistService.delete(pl)
                if selectedPlaylist?.id == pid { selectedPlaylist = nil }
            }
        case .youtube:
            if let yid = item.youTubeImportId {
                importService.deleteImport(importId: yid)
                if selectedYouTubeImport?.id == yid { selectedYouTubeImport = nil }
            }
        }
        refreshPlaylists()
    }

    private func handlePlaylistTap(_ item: SidebarPlaylistItem) {
        selection = .playlists
        switch item.origin {
        case .local:
            if let pid = item.playlistId,
               let playlist = playlists.first(where: { $0.id == pid }) {
                selectedYouTubeImport = nil
                selectedPlaylist = playlist
                NotificationCenter.default.post(name: .musesSelectPlaylist, object: playlist)
            }
        case .youtube:
            if let yid = item.youTubeImportId,
               let imp = ytImports.first(where: { $0.id == yid }) {
                selectedPlaylist = nil
                selectedYouTubeImport = imp
                NotificationCenter.default.post(name: .musesNavigateYouTubeImport, object: imp)
            }
        }
    }

    private func isPlaylistSelected(_ item: SidebarPlaylistItem) -> Bool {
        switch item.origin {
        case .local:
            return selectedPlaylist?.id == item.playlistId
        case .youtube:
            return selectedYouTubeImport?.id == item.youTubeImportId
        }
    }

    private func refreshPlaylists() {
        playlists = playlistService.fetchAll()
    }
}

extension Notification.Name {
    static let musesSelectPlaylist = Notification.Name("muses.selectPlaylist")
    static let musesPlaylistsChanged = Notification.Name("muses.playlistsChanged")
}
