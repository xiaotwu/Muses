import SwiftUI
import AppKit
import SwiftData

/// Apple Music Web left nav: Search / Home / New, then Library + playlists, profile at the bottom.
struct SidebarView: View {
    var onSettingsCategoryChange: () -> Void = {}
    @Binding var selection: SidebarSection
    @Binding var selectedPlaylist: Playlist?
    @Binding var selectedYouTubeImport: YouTubeImport?
    @Binding var isCollapsed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PlaylistService.self) private var playlistService
    @Environment(YouTubeImportService.self) private var importService
    @Environment(YouTubePlaylistSyncService.self) private var playlistSync
    @AppStorage(PrefKey.settingsLastPane) private var settingsPane = SettingsCategory.general.rawValue
    @State private var playlists: [Playlist] = []
    @Query(sort: \YouTubeImport.importedAt, order: .reverse) private var ytImports: [YouTubeImport]
    @State private var showCreatePlaylist = false
    @State private var showPlaylistChoice = false
    @State private var showImportPlaylist = false
    @State private var operationError: String?
    @FocusState private var focusedDestination: SidebarSection?

    init(
        selection: Binding<SidebarSection>,
        selectedPlaylist: Binding<Playlist?>,
        selectedYouTubeImport: Binding<YouTubeImport?>,
        isCollapsed: Binding<Bool> = .constant(false),
        onSettingsCategoryChange: @escaping () -> Void = {}
    ) {
        self.onSettingsCategoryChange = onSettingsCategoryChange
        _selection = selection
        _selectedPlaylist = selectedPlaylist
        _selectedYouTubeImport = selectedYouTubeImport
        _isCollapsed = isCollapsed
    }

    private var settingsNavigation: some View {
        VStack(alignment: .leading, spacing: 2) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsCategory.allCases) { category in
                        if !isCollapsed, category == .youtube { sectionLabel(tr("Content", "内容", zhHant: "內容")) }
                        if !isCollapsed, category == .diagnostics { sectionLabel(tr("Maintenance & Help", "维护与帮助", zhHant: "維護與說明")) }
                        let selected = (SettingsCategory(rawValue: settingsPane) ?? .general).destination == category
                        Button { onSettingsCategoryChange(); settingsPane = category.rawValue } label: {
                            HStack(spacing: 10) {
                                Image(systemName: category.toolbarIcon).frame(width: 18)
                                if !isCollapsed { Text(category.sidebarLabel) }
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: AppleMusicTokens.navItemHeight, alignment: .leading)
                            .settingsSelection(selected)
                            .foregroundStyle(BrandColors.textPrimary)
                        }
                        .buttonStyle(.plain)
                        .help(category.label)
                        .accessibilityLabel(category.label)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            Spacer(minLength: 8)
        }
    }

    var body: some View {
        Group {
            if selection == .settings {
                settingsNavigation
            } else if isCollapsed {
                collapsedBody
            } else {
                expandedBody
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
        .frame(width: isCollapsed ? AppleMusicTokens.sidebarCollapsedWidth : AppleMusicTokens.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            Color.clear
                .musesGlass(in: SidebarPaneShape.shape, role: .persistentChrome)
                .ignoresSafeArea(.container, edges: .top)
                .allowsHitTesting(false)
        }
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
        .onChange(of: isCollapsed) { _, _ in
            focusedDestination = selection
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
            ScrollView {
            VStack(alignment: .leading, spacing: 2) {
            navRow("magnifyingglass", SidebarSection.search.title, .search)
            navRow("house.fill", SidebarSection.home.title, .home)
            navRow("square.grid.2x2.fill", SidebarSection.new.title, .new)

            sectionLabel(tr("Library", "资料库"))
            navRow("music.note", SidebarSection.songs.title, .songs)
            navRow("square.stack", SidebarSection.albums.title, .albums)
            navRow("person.2", SidebarSection.artists.title, .artists)
            navRow("heart.fill", SidebarSection.liked.title, .liked)
            navRow("play.rectangle.fill", SidebarSection.musicVideos.title, .musicVideos)
            navRow("person.crop.rectangle.stack", SidebarSection.subscriptions.title, .subscriptions)
            navRow("clock.arrow.circlepath", SidebarSection.history.title, .history)

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
            VStack(spacing: 1) {
                    ForEach(orderedItems) { item in
                        PlaylistSidebarRow(
                            item: item,
                            isSelected: isPlaylistSelected(item)
                        ) { handlePlaylistTap(item) }
                        .contextMenu {
                            Button(tr("Open", "打开")) { handlePlaylistTap(item) }
                            if let importID = item.youTubeImportId,
                               let imported = ytImports.first(where: { $0.id == importID }),
                               let url = URL(string: imported.url),
                               let target = YouTubeShareTarget(url: url) {
                                YouTubeShareMenu(target: target)
                            }
                            Button(tr("Remove", "移除"), role: .destructive) {
                                removeSidebarItem(item)
                            }
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
            ScrollView {
            VStack(spacing: 6) {
            collapsedNavRow("magnifyingglass", SidebarSection.search.title, .search)
            collapsedNavRow("house.fill", SidebarSection.home.title, .home)
            collapsedNavRow("square.grid.2x2.fill", SidebarSection.new.title, .new)

            Divider()
                .padding(.horizontal, 16)
                .padding(.vertical, 4)

            collapsedNavRow("music.note", SidebarSection.songs.title, .songs)
            collapsedNavRow("square.stack", SidebarSection.albums.title, .albums)
            collapsedNavRow("person.2", SidebarSection.artists.title, .artists)
            collapsedNavRow("heart.fill", SidebarSection.liked.title, .liked)
            collapsedNavRow("play.rectangle.fill", SidebarSection.musicVideos.title, .musicVideos)
            collapsedNavRow("person.crop.rectangle.stack", SidebarSection.subscriptions.title, .subscriptions)
            collapsedNavRow("clock.arrow.circlepath", SidebarSection.history.title, .history)
            collapsedNavRow("music.note.list", SidebarSection.playlists.title, .playlists) {
                selectedPlaylist = nil
                selectedYouTubeImport = nil
                NotificationCenter.default.post(name: .musesShowPlaylistsOverview, object: nil)
            }

            }
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
                                 ? BrandColors.accent : BrandColors.textPrimary.opacity(on ? 1 : 0.85))
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(on ? BrandColors.accent.opacity(0.18) : Color.clear)
                        .selectionHalo(on)
                )
        }
        .buttonStyle(.plain)
        .focused($focusedDestination, equals: tag)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityLabel(title)
        .help(title)
    }

    private var collapsedProfileRow: some View {
        Button {
            NotificationCenter.default.post(name: .musesOpenSettings, object: nil)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "gearshape").font(.system(size: 16, weight: .semibold))
                Text(tr("Settings", "设置", zhHant: "設定")).font(.system(size: 10, weight: .medium))
            }
                .foregroundStyle(selection == .settings ? BrandColors.accent : BrandColors.textSecondary)
                .frame(width: 72, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == .settings ? .isSelected : [])
        .help(SidebarNavPolicy.settingsFooterTitle())
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
                             ? BrandColors.accent : BrandColors.textPrimary.opacity(on ? 1 : 0.85))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: AppleMusicTokens.navItemHeight, alignment: .leading)
            .settingsSelection(on)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedDestination, equals: tag)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityLabel(title)
    }

    private var profileRow: some View {
        navRow("gearshape", tr("Settings", "设置", zhHant: "設定"), .settings) {
            NotificationCenter.default.post(name: .musesOpenSettings, object: nil)
        }
        .help(SidebarNavPolicy.settingsFooterTitle())
        .accessibilityLabel(tr("Open Settings", "打开设置", zhHant: "開啟設定"))
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
