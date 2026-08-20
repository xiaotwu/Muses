import SwiftUI
import AppKit
import SwiftData

/// Apple Music Web left nav: Search / Home / New, then Library + playlists, profile at the bottom.
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
    @Environment(YouTubeAccountService.self) private var youTubeAccount
    @Environment(GlobalSearchService.self) private var search
    @State private var playlists: [Playlist] = []
    @Query(sort: \YouTubeImport.importedAt, order: .reverse) private var ytImports: [YouTubeImport]
    @State private var showCreatePlaylist = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TrafficLightsPad()
                .frame(width: 72, height: 16)
                .padding(.top, 14)
                .padding(.leading, 8)
                .padding(.bottom, 10)
            MusesWordmark()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            navRow("magnifyingglass", tr("Search", "搜索"), .search)
            navRow("house.fill", tr("Home", "首页"), .home)
            navRow("square.grid.2x2.fill", tr("New", "新发现"), .new)

            sectionLabel(tr("Library", "资料库"))
            navRow("clock", tr("Recently", "最近"), .recently)
            navRow("music.note", tr("Songs", "歌曲"), .songs)
            navRow("clock.arrow.circlepath", tr("History", "历史记录"), .history)
            navRow("tray", tr("Inbox", "收件箱"), .inbox)

            sectionLabel(tr("Playlists", "歌单"))
            navRow("music.note.list", tr("All Playlists", "全部歌单"), .playlists) {
                selectedPlaylist = nil
                selectedYouTubeImport = nil
                NotificationCenter.default.post(name: .musesShowPlaylistsOverview, object: nil)
            }
            ScrollView {
                VStack(spacing: 1) {
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
                }
            }

            Spacer(minLength: 8)
            profileRow
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
        .frame(width: AppleMusicTokens.sidebarWidth)
        .background {
            RoundedRectangle(cornerRadius: AppleMusicTokens.sidebarCorner, style: .continuous)
                .fill(BrandColors.surface.opacity(0.55))
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppleMusicTokens.sidebarCorner, style: .continuous)
                .stroke(BrandColors.textPrimary.opacity(0.06), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppleMusicTokens.sidebarCorner, style: .continuous))
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

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(BrandColors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private var searchSelected: Bool {
        selection == .search || SearchChromePolicy.occupiesContent(query: search.query)
    }

    private func isNavSelected(_ tag: SidebarSection) -> Bool {
        if tag == .search { return searchSelected }
        if tag == .playlists {
            return selection == .playlists && selectedPlaylist == nil && selectedYouTubeImport == nil
        }
        return selection == tag
    }

    private func navRow(_ icon: String, _ title: String, _ tag: SidebarSection,
                        extra: (() -> Void)? = nil) -> some View {
        let on = isNavSelected(tag)
        return Button {
            showSettings = false
            selectedPlaylist = nil
            selectedYouTubeImport = nil
            selection = tag
            extra?()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: on ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(on && AppleMusicChrome.selectedNavUsesAccent
                             ? BrandColors.magenta : BrandColors.textPrimary.opacity(on ? 1 : 0.85))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: AppleMusicTokens.navItemHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(on ? BrandColors.textPrimary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityLabel(title)
    }

    private var profileRow: some View {
        Button {
            showSettings = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(BrandColors.textSecondary)
                Text(youTubeAccount.account?.channel?.title
                     ?? tr("Settings", "设置"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .help(tr("Settings", "设置"))
        .accessibilityLabel(tr("Open Settings", "打开设置"))
    }

    private func libraryRow(_ icon: String, _ title: String, _ tag: SidebarSection) -> some View {
        navRow(icon, title, tag)
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
        showSettings = false
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
