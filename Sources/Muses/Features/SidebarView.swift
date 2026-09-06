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
    @Binding var isCollapsed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PlaylistService.self) private var playlistService
    @Environment(YouTubeImportService.self) private var importService
    @Environment(YouTubeAccountService.self) private var youTubeAccount
    @Environment(YouTubePlaylistSyncService.self) private var playlistSync
    @State private var playlists: [Playlist] = []
    @Query(sort: \YouTubeImport.importedAt, order: .reverse) private var ytImports: [YouTubeImport]
    @State private var showCreatePlaylist = false
    @State private var showPlaylistChoice = false
    @State private var showImportPlaylist = false
    @State private var operationError: String?

    init(
        selection: Binding<SidebarSection>,
        showSettings: Binding<Bool>,
        showAbout: Binding<Bool>,
        initialSettingsCategory: Binding<SettingsCategory?>,
        selectedPlaylist: Binding<Playlist?>,
        selectedYouTubeImport: Binding<YouTubeImport?>,
        isCollapsed: Binding<Bool> = .constant(false)
    ) {
        _selection = selection
        _showSettings = showSettings
        _showAbout = showAbout
        _initialSettingsCategory = initialSettingsCategory
        _selectedPlaylist = selectedPlaylist
        _selectedYouTubeImport = selectedYouTubeImport
        _isCollapsed = isCollapsed
    }

    var body: some View {
        Group {
            if isCollapsed {
                collapsedBody
            } else {
                expandedBody
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
        .frame(width: isCollapsed ? AppleMusicTokens.sidebarCollapsedWidth : AppleMusicTokens.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .musesGlass(in: SidebarPaneShape.shape, role: .persistentChrome)
        .clipShape(SidebarPaneShape.shape)
        .sheet(isPresented: $showCreatePlaylist) {
            NewPlaylistSheet(isPresented: $showCreatePlaylist) { name in
                playlistService.create(name: name)
                refreshPlaylists()
            }
        }
        .sheet(isPresented: $showPlaylistChoice) {
            PlaylistAddChoiceSheet {
                showPlaylistChoice = false
                DispatchQueue.main.async { showCreatePlaylist = true }
            } onImport: {
                showPlaylistChoice = false
                DispatchQueue.main.async { showImportPlaylist = true }
            }
        }
        .sheet(isPresented: $showImportPlaylist) {
            YouTubeImportSheet { url in
                Task {
                    do {
                        _ = try await importService.importPlaylist(url: url)
                        showImportPlaylist = false
                    } catch {
                        operationError = error.localizedDescription
                    }
                }
            }
        }
        .alert(tr("Playlist Error", "歌单错误"), isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button(tr("OK", "确定")) { operationError = nil }
        } message: {
            Text(operationError ?? "")
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

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            TrafficLightsPad()
                .padding(.top, WindowChromeMetrics.trafficLightTopInset)
                .padding(.bottom, 2)

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    MusesMark(size: 20)
                    Text("Muses")
                        .font(BrandFont.muses(22))
                        .foregroundStyle(BrandColors.textPrimary)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(MusesMotion.drawerAnimation(reduceMotion: reduceMotion)) {
                        isCollapsed = true
                    }
                } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BrandColors.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("Collapse Sidebar", "折叠边栏"))
                .accessibilityLabel(tr("Collapse Sidebar", "折叠边栏"))
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)

            navRow("magnifyingglass", tr("Search", "搜索"), .search)
            navRow("house.fill", tr("Home", "首页"), .home)
            navRow("square.grid.2x2.fill", tr("Discover", "发现"), .new)

            sectionLabel(tr("Library", "资料库"))
            navRow("music.note", tr("Songs", "歌曲"), .songs)
            navRow("square.stack", tr("Albums", "专辑"), .albums)
            navRow("person.2", tr("Artists", "艺术家"), .artists)
            navRow("clock.arrow.circlepath", tr("History", "历史记录"), .history)

            sectionLabel(tr("Playlists", "歌单"))
            HStack(spacing: 3) {
                navRow("music.note.list", tr("All Playlists", "全部歌单"), .playlists) {
                    selectedPlaylist = nil
                    selectedYouTubeImport = nil
                    NotificationCenter.default.post(name: .musesShowPlaylistsOverview, object: nil)
                }
                ChromeIconButton(
                    systemName: "plus",
                    help: tr("Add Playlist", "添加歌单"),
                    accessibility: tr("Add Playlist", "添加歌单")
                ) { showPlaylistChoice = true }
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
    }

    private var collapsedBody: some View {
        VStack(spacing: 6) {
            TrafficLightsPad()
                .padding(.top, WindowChromeMetrics.trafficLightTopInset)
                .padding(.bottom, 2)

            Button {
                withAnimation(MusesMotion.drawerAnimation(reduceMotion: reduceMotion)) {
                    isCollapsed = false
                }
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(BrandColors.textPrimary.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(BrandColors.surface.opacity(0.8))
                    )
            }
            .buttonStyle(.plain)
            .help(tr("Expand Sidebar", "展开边栏"))
            .accessibilityLabel(tr("Expand Sidebar", "展开边栏"))
            .padding(.bottom, 6)

            collapsedNavRow("magnifyingglass", tr("Search", "搜索"), .search)
            collapsedNavRow("house.fill", tr("Home", "首页"), .home)
            collapsedNavRow("square.grid.2x2.fill", tr("Discover", "发现"), .new)

            Divider()
                .padding(.horizontal, 16)
                .padding(.vertical, 4)

            collapsedNavRow("music.note", tr("Songs", "歌曲"), .songs)
            collapsedNavRow("square.stack", tr("Albums", "专辑"), .albums)
            collapsedNavRow("person.2", tr("Artists", "艺术家"), .artists)
            collapsedNavRow("clock.arrow.circlepath", tr("History", "历史记录"), .history)
            collapsedNavRow("music.note.list", tr("Playlists", "歌单"), .playlists) {
                selectedPlaylist = nil
                selectedYouTubeImport = nil
                NotificationCenter.default.post(name: .musesShowPlaylistsOverview, object: nil)
            }

            Spacer(minLength: 8)
            collapsedProfileRow
        }
    }

    private func collapsedNavRow(
        _ icon: String,
        _ title: String,
        _ tag: SidebarSection,
        extra: (() -> Void)? = nil
    ) -> some View {
        let on = isNavSelected(tag)
        return Button {
            showSettings = false
            if tag == .search {
                NotificationCenter.default.post(name: .musesFocusSearch, object: nil)
                extra?()
                return
            }
            selectedPlaylist = nil
            selectedYouTubeImport = nil
            selection = tag
            extra?()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(on && AppleMusicChrome.selectedNavUsesAccent
                                 ? BrandColors.magenta : BrandColors.textPrimary.opacity(on ? 1 : 0.85))
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(on ? BrandColors.magenta.opacity(0.18) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityLabel(title)
        .help(title)
    }

    private var collapsedProfileRow: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(BrandColors.textSecondary)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .help(tr("Settings", "设置"))
        .accessibilityLabel(tr("Open Settings", "打开设置"))
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(BrandColors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private func isNavSelected(_ tag: SidebarSection) -> Bool {
        if tag == .search { return false }
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
            if tag == .search {
                NotificationCenter.default.post(name: .musesFocusSearch, object: nil)
                extra?()
                return
            }
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

    private var mergedItems: [SidebarPlaylistItem] {
        PlaylistSidebarAdapter.merged(
            local: playlists,
            youTube: ytImports.filter { $0.deletedAt == nil }
        )
    }

    private var orderedItems: [SidebarPlaylistItem] {
        SidebarPlaylistOrder.apply(mergedItems)
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
                do {
                    try playlistSync.moveToRecentlyDeleted(importID: yid)
                    if selectedYouTubeImport?.id == yid { selectedYouTubeImport = nil }
                } catch {
                    operationError = error.localizedDescription
                }
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
               let imp = ytImports.first(where: { $0.id == yid && $0.deletedAt == nil }) {
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
