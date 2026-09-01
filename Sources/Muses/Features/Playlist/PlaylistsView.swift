import AppKit
import SwiftData
import SwiftUI

/// Playlist overview: shows all playlists plus create/delete.
struct PlaylistsView: View {
    @Environment(PlaylistService.self) private var playlistService
    @Environment(PlaybackService.self) private var playback
    @Environment(YouTubeImportService.self) private var importService
    @Environment(YouTubePlaylistSyncService.self) private var playlistSync
    @Binding var selectedPlaylist: Playlist?
    @Query(sort: \YouTubeImport.importedAt, order: .reverse) private var ytImports: [YouTubeImport]
    @State private var playlists: [Playlist] = []
    @State private var showCreateSheet = false
    @State private var showAddChoice = false
    @State private var showImportSheet = false
    @State private var addError: String?
    @State private var revisionImport: YouTubeImport?
    @State private var pendingDeletion: PlaylistDeletionTarget?
    @State private var undoablePlaylistDeletion: PlaylistDeletionSnapshot?
    @State private var syncStatuses: [UUID: YouTubePlaylistOverviewStatus] = [:]

    private var activeYouTubeImports: [YouTubeImport] {
        ytImports.filter { $0.deletedAt == nil }
    }

    private var deletedYouTubeImports: [YouTubeImport] {
        ytImports.filter { YouTubePlaylistSyncService.isWithinRecentlyDeletedRetention($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Text(tr("All Playlists", "全部歌单"))
                    .font(.system(size: AppleMusicTokens.pageTitleSize, weight: .heavy))
                    .foregroundStyle(BrandColors.textPrimary)
                Spacer(minLength: 16)
                ChromeIconButton(
                    systemName: "plus",
                    help: tr("New Playlist", "新建歌单"),
                    accessibility: tr("New Playlist", "新建歌单")
                ) { showAddChoice = true }
            }
            .padding(.horizontal, AppleMusicTokens.contentPaddingX)
            .padding(.top, AppleMusicSpacing.browseTitleTop)
            .padding(.bottom, AppleMusicSpacing.headerToPrimary)

            if let addError {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(addError).lineLimit(2)
                    Spacer()
                    Button(tr("Dismiss", "关闭")) { self.addError = nil }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
                .padding(.horizontal, AppleMusicTokens.contentPaddingX)
                .padding(.bottom, 10)
            }

            if let deleted = undoablePlaylistDeletion {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.uturn.backward")
                    Text(tr("\(deleted.name) was deleted", "已删除 \(deleted.name)"))
                        .lineLimit(1)
                    Spacer()
                    Button(tr("Undo", "撤销"), action: undoPlaylistDeletion)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
                .padding(.horizontal, AppleMusicTokens.contentPaddingX)
                .padding(.bottom, 10)
            }

            if let loadError = playlistService.loadState.errorMessage {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlistService.loadState.isStale
                             ? tr("Showing saved playlists", "正在显示已保存的歌单")
                             : tr("Playlists could not be loaded", "无法载入歌单"))
                            .font(.callout.weight(.semibold))
                        Text(loadError).font(.caption).lineLimit(2)
                    }
                    Spacer()
                    Button(tr("Retry", "重试"), action: refresh)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .foregroundStyle(BrandColors.textSecondary)
                .padding(.horizontal, AppleMusicTokens.contentPaddingX)
                .padding(.bottom, 10)
            }

            ScrollView {
                if playlistService.loadState.isLoading,
                   playlistService.loadState.value == nil {
                    ProgressView(tr("Loading playlists…", "正在载入歌单…"))
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if playlistService.loadState.errorMessage != nil,
                          playlistService.loadState.value == nil,
                          activeYouTubeImports.isEmpty,
                          deletedYouTubeImports.isEmpty {
                    EmptyStateView(
                        icon: "exclamationmark.triangle",
                        title: tr("Playlists unavailable", "歌单暂不可用"),
                        subtitle: tr("Retry to load playlists from this Mac.",
                                     "请重试从此 Mac 载入歌单。"))
                        .padding(16)
                } else if playlists.isEmpty && activeYouTubeImports.isEmpty
                    && deletedYouTubeImports.isEmpty {
                    playlistEmptyState
                        .padding(16)
                } else {
                    LazyVGrid(columns: [
                        GridItem(
                            .adaptive(
                                minimum: PlaylistOverviewMetrics.minimumColumnWidth,
                                maximum: PlaylistOverviewMetrics.maximumColumnWidth
                            ),
                            spacing: PlaylistOverviewMetrics.columnSpacing
                        )
                    ], alignment: .leading, spacing: PlaylistOverviewMetrics.rowSpacing) {
                        ForEach(playlists, id: \.id) { playlist in
                            let snapshots = playlistSnapshots(playlist)
                            AlbumObjectView(
                                title: playlist.name,
                                subtitle: playlistSubtitle(playlist),
                                artwork: playlistArtwork(playlist),
                                size: PlaylistOverviewMetrics.cardWidth,
                                cornerRadius: PlaylistOverviewMetrics.cornerRadius,
                                role: .browse,
                                style: .home,
                                artworkHeight: PlaylistOverviewMetrics.artworkHeight,
                                footerHeight: PlaylistOverviewMetrics.footerHeight,
                                homeCornerRadius: PlaylistOverviewMetrics.cornerRadius,
                                hoverLift: PlaylistOverviewMetrics.hoverLift,
                                pressedScale: PlaylistOverviewMetrics.pressedScale,
                                showsHoverPlay: !snapshots.isEmpty,
                                onSelect: { selectedPlaylist = playlist },
                                onPlay: { playPlaylist(playlist) }
                            )
                            .contextMenu {
                                Button(tr("Open Playlist", "打开歌单"), systemImage: "arrow.forward.circle") {
                                    selectedPlaylist = playlist
                                }
                                if !playlistSnapshots(playlist).isEmpty {
                                    Button(tr("Play", "播放"), systemImage: "play.fill") {
                                        playPlaylist(playlist)
                                    }
                                }
                                Button(
                                    playlist.pinned ? tr("Unpin", "取消钉选") : tr("Pin", "钉选"),
                                    systemImage: playlist.pinned ? "pin.slash" : "pin"
                                ) {
                                    playlistService.togglePin(playlist)
                                    refresh()
                                }
                                Divider()
                                Button(tr("Delete Playlist", "删除歌单"), systemImage: "trash",
                                       role: .destructive) {
                                    pendingDeletion = .playlist(playlist)
                                }
                            }
                        }
                        ForEach(activeYouTubeImports, id: \.id) { imp in
                            let snapshots = importSnapshots(imp)
                            AlbumObjectView(
                                title: imp.title,
                                subtitle: importSubtitle(imp),
                                artwork: youtubeArtwork(imp),
                                size: PlaylistOverviewMetrics.cardWidth,
                                cornerRadius: PlaylistOverviewMetrics.cornerRadius,
                                role: .browse,
                                style: .home,
                                artworkHeight: PlaylistOverviewMetrics.artworkHeight,
                                footerHeight: PlaylistOverviewMetrics.footerHeight,
                                homeCornerRadius: PlaylistOverviewMetrics.cornerRadius,
                                hoverLift: PlaylistOverviewMetrics.hoverLift,
                                pressedScale: PlaylistOverviewMetrics.pressedScale,
                                isYouTube: true,
                                showsHoverPlay: !snapshots.isEmpty,
                                onSelect: {
                                    NotificationCenter.default.post(
                                        name: .musesNavigateYouTubeImport, object: imp)
                                },
                                onPlay: { playYouTubeImport(imp) }
                            )
                            .overlay(alignment: .topLeading) {
                                if let status = syncStatuses[imp.id] {
                                    syncStatusBadge(status)
                                        .padding(8)
                                }
                            }
                            .contextMenu {
                                Button(tr("Open Playlist", "打开歌单"), systemImage: "arrow.forward.circle") {
                                    NotificationCenter.default.post(
                                        name: .musesNavigateYouTubeImport, object: imp)
                                }
                                if !importSnapshots(imp).isEmpty {
                                    Button(tr("Play", "播放"), systemImage: "play.fill") {
                                        playYouTubeImport(imp)
                                    }
                                }
                                Button(syncMenuLabel(imp), systemImage: "arrow.left.arrow.right") {
                                    NotificationCenter.default.post(
                                        name: .musesNavigateYouTubeImport, object: imp)
                                }
                                Button(tr("Version History…", "版本历史…"), systemImage: "clock.arrow.circlepath") {
                                    revisionImport = imp
                                }
                                if let url = URL(string: imp.url) {
                                    Button {
                                        NSWorkspace.shared.open(url)
                                    } label: {
                                        Label {
                                            Text(tr("Open on YouTube", "在 YouTube 打开"))
                                        } icon: {
                                            YouTubeMark(size: 12)
                                                .accessibilityHidden(true)
                                        }
                                    }
                                    .accessibilityLabel(tr("Open on YouTube", "在 YouTube 打开"))
                                }
                                Divider()
                                Button(tr("Delete Import", "删除导入"), systemImage: "trash",
                                       role: .destructive) {
                                    pendingDeletion = .youTubeImport(imp)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, AppleMusicTokens.contentPaddingX)
                    .padding(.bottom, AppleMusicTokens.scrollBottomInset)

                    if !deletedYouTubeImports.isEmpty {
                        recentlyDeletedSection
                            .padding(.horizontal, AppleMusicTokens.contentPaddingX)
                            .padding(.bottom, AppleMusicTokens.scrollBottomInset)
                    }
                }
            }
        }
        .background(BrowseBackground())
        .sheet(isPresented: $showCreateSheet) {
            NewPlaylistSheet(isPresented: $showCreateSheet) { name in
                playlistService.create(name: name)
                refresh()
            }
        }
        .sheet(isPresented: $showAddChoice) {
            PlaylistAddChoiceSheet {
                showAddChoice = false
                DispatchQueue.main.async { showCreateSheet = true }
            } onImport: {
                showAddChoice = false
                DispatchQueue.main.async { showImportSheet = true }
            }
        }
        .sheet(isPresented: $showImportSheet) {
            YouTubeImportSheet { url in
                Task {
                    do {
                        _ = try await importService.importPlaylist(url: url)
                        addError = nil
                        showImportSheet = false
                    } catch {
                        addError = error.localizedDescription
                    }
                }
            }
        }
        .sheet(item: $revisionImport) { imported in
            PlaylistRevisionBrowserSheet(importID: imported.id,
                                         playlistTitle: imported.title)
        }
        .confirmationDialog(
            pendingDeletion?.title ?? "",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(tr("Delete", "删除"), role: .destructive) {
                confirmDeletion()
            }
            Button(tr("Cancel", "取消"), role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text(pendingDeletion?.message ?? "")
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .musesPlaylistsChanged)) { _ in
            refresh()
        }
    }

    private func refresh() {
        playlists = playlistService.fetchAll()
        syncStatuses = Dictionary(uniqueKeysWithValues: activeYouTubeImports.compactMap { imported in
            guard let status = try? playlistSync.overviewStatus(importID: imported.id) else {
                return nil
            }
            return (imported.id, status)
        })
    }

    private func deletePlaylist(_ playlist: Playlist) {
        undoablePlaylistDeletion = playlistService.deleteWithUndoSnapshot(playlist)
        if undoablePlaylistDeletion != nil { refresh() }
    }

    private func deleteYouTubeImport(_ imported: YouTubeImport) {
        do {
            try playlistSync.moveToRecentlyDeleted(importID: imported.id)
            addError = nil
        } catch {
            addError = error.localizedDescription
        }
    }

    private func confirmDeletion() {
        let target = pendingDeletion
        pendingDeletion = nil
        switch target {
        case .playlist(let playlist): deletePlaylist(playlist)
        case .youTubeImport(let imported): deleteYouTubeImport(imported)
        case nil: break
        }
    }

    private func undoPlaylistDeletion() {
        guard let snapshot = undoablePlaylistDeletion,
              playlistService.restore(snapshot) != nil else { return }
        undoablePlaylistDeletion = nil
        refresh()
    }

    private func restoreYouTubeImport(_ imported: YouTubeImport) {
        do {
            guard let revision = try playlistSync.revisions(importID: imported.id)
                .first(where: { $0.kind == .beforeDelete }) else {
                addError = tr("No local recovery revision is available", "没有可用的本地恢复版本")
                return
            }
            try playlistSync.restore(revisionID: revision.id)
            addError = nil
        } catch {
            addError = error.localizedDescription
        }
    }

    private func playPlaylist(_ playlist: Playlist) {
        let snaps = playlistSnapshots(playlist)
        guard let first = snaps.first else { return }
        playback.playTrack(first, context: snaps, from: .playlist)
    }

    private func playYouTubeImport(_ imp: YouTubeImport) {
        let snaps = importSnapshots(imp)
        guard let first = snaps.first else { return }
        playback.playTrack(first, context: snaps, from: .import)
    }

    private func importSnapshots(_ imp: YouTubeImport) -> [TrackSnapshot] {
        (imp.items ?? []).sorted { $0.order < $1.order }
            .compactMap(\.track)
            .filter { !$0.youTubeId.isEmpty }
            .map(TrackSnapshot.init(from:))
    }

    private func youtubeArtwork(_ imp: YouTubeImport) -> ArtworkSource {
        if let urlStr = imp.artworkUrl, let url = URL(string: urlStr) {
            return .remote(url)
        }
        if let vid = (imp.items ?? []).sorted(by: { $0.order < $1.order }).first?.youTubeId,
           let url = YouTubeEmbed.thumbnailURL(videoId: vid) {
            return .remote(url)
        }
        return .placeholder
    }

    private func playlistArtwork(_ playlist: Playlist) -> ArtworkSource {
        guard let snapshot = playlistSnapshots(playlist).first else {
            return .placeholder
        }
        return ArtworkSource.resolve(for: snapshot)
    }

    private func playlistSnapshots(_ playlist: Playlist) -> [TrackSnapshot] {
        (playlist.items ?? [])
            .sorted { $0.order < $1.order }
            .compactMap(\.track)
            .filter { !$0.youTubeId.isEmpty }
            .map(TrackSnapshot.init(from:))
    }

    private func playlistSubtitle(_ playlist: Playlist) -> String {
        let count = playlistSnapshots(playlist).count
        return tr("Muses • \(count) songs", "Muses • \(count) 首歌曲")
    }

    private func importSubtitle(_ imported: YouTubeImport) -> String {
        let count = (imported.items ?? []).filter { !$0.youTubeId.isEmpty }.count
        let owner = imported.channel.isEmpty
            ? tr("Unknown owner", "未知所有者") : imported.channel
        guard let status = syncStatuses[imported.id] else {
            return tr("YouTube • \(count) songs • \(owner)",
                      "YouTube • \(count) 首歌曲 • \(owner)")
        }
        let activity = syncActivitySummary(status)
        return tr("YouTube • \(count) songs • \(owner)\n\(activity)",
                  "YouTube • \(count) 首歌曲 • \(owner)\n\(activity)")
    }

    private var playlistEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(BrandColors.textSecondary)
            Text(tr("No playlists", "暂无歌单"))
                .font(.title3.weight(.semibold))
            Text(tr("Create a Muses playlist or import one from YouTube.",
                    "创建 Muses 歌单，或从 YouTube 导入歌单。"))
                .font(.callout)
                .foregroundStyle(BrandColors.textSecondary)
            HStack(spacing: 10) {
                Button(tr("New Playlist", "新建歌单")) { showCreateSheet = true }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandColors.magenta)
                Button(tr("Import YouTube Playlist", "导入 YouTube 歌单")) {
                    showImportSheet = true
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private func syncMenuLabel(_ imported: YouTubeImport) -> String {
        if syncStatuses[imported.id]?.remoteWritable == true {
            return tr("Open Check / Pull / Push", "打开检查 / 拉取 / 推送")
        }
        return tr("Open Check / Pull", "打开检查 / 拉取")
    }

    private func syncActivitySummary(_ status: YouTubePlaylistOverviewStatus) -> String {
        var parts: [String] = []
        if let checked = status.lastRemoteCheckAt {
            parts.append(tr("Checked \(checked.formatted(date: .abbreviated, time: .omitted))",
                            "检查于 \(checked.formatted(date: .abbreviated, time: .omitted))"))
        } else {
            parts.append(tr("Not checked", "尚未检查"))
        }
        if let pushed = status.lastPushAt {
            parts.append(tr("Pushed \(pushed.formatted(date: .abbreviated, time: .omitted))",
                            "推送于 \(pushed.formatted(date: .abbreviated, time: .omitted))"))
        }
        if let pulled = status.lastPullAt {
            parts.append(tr("Pulled \(pulled.formatted(date: .abbreviated, time: .omitted))",
                            "拉取于 \(pulled.formatted(date: .abbreviated, time: .omitted))"))
        }
        if status.pendingLocalChangeCount > 0 {
            parts.append(tr("\(status.pendingLocalChangeCount) pending",
                            "\(status.pendingLocalChangeCount) 项待推送"))
        }
        return parts.joined(separator: " • ")
    }

    private func syncStatusBadge(_ status: YouTubePlaylistOverviewStatus) -> some View {
        let appearance = syncBadgeAppearance(status)
        return Label(appearance.text, systemImage: appearance.icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(appearance.color)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(BrandColors.surface.opacity(0.94),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(BrandColors.hairline, lineWidth: 1)
            }
            .help(appearance.help)
            .accessibilityLabel(appearance.help)
    }

    private func syncBadgeAppearance(_ status: YouTubePlaylistOverviewStatus)
        -> (text: String, icon: String, color: Color, help: String) {
        if status.needsReview || status.conflictCount > 0 || status.errorMessage != nil {
            let message = status.errorMessage ?? tr(
                "This playlist needs sync review.", "此歌单需要同步复核。")
            return (tr("Review", "需复核"), "exclamationmark.triangle.fill",
                    BrandColors.magenta, message)
        }
        if status.hasIncompleteRemote {
            return (tr("Partial", "未完整"), "arrow.clockwise.circle",
                    BrandColors.textPrimary,
                    tr("Remote reading is incomplete. Continue Check Remote before Pull or Push.",
                       "远端尚未读取完整；拉取或推送前请继续检查远端。"))
        }
        if status.pendingLocalChangeCount > 0 {
            return (tr("\(status.pendingLocalChangeCount) pending",
                       "\(status.pendingLocalChangeCount) 项待推送"),
                    "arrow.up.circle.fill", BrandColors.textPrimary,
                    tr("Local changes are waiting for Push.", "本地修改正在等待推送。"))
        }
        if status.remoteWritable == false {
            return (tr("Read only", "只读"), "lock.fill", BrandColors.textPrimary,
                    tr("The active account cannot Push to this playlist.",
                       "当前账号无法向此歌单推送。"))
        }
        return (tr("Synced", "已同步"), "checkmark.circle.fill", BrandColors.textPrimary,
                tr("No known local changes are waiting for Push.", "没有已知的本地修改等待推送。"))
    }

    private var recentlyDeletedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Recently Deleted", "最近删除"))
                .font(.headline)
            Text(tr("Local recovery is available for 30 days. Restoring never pushes to YouTube.",
                    "本地恢复保留 30 天，恢复操作不会推送到 YouTube。"))
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
            ForEach(deletedYouTubeImports, id: \.id) { imported in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(imported.title)
                        if let deletedAt = imported.deletedAt {
                            Text(tr("Deleted \(deletedAt.formatted(date: .abbreviated, time: .omitted))",
                                    "删除于 \(deletedAt.formatted(date: .abbreviated, time: .omitted))"))
                                .font(.caption)
                                .foregroundStyle(BrandColors.textSecondary)
                        }
                    }
                    Spacer()
                    Button(tr("Restore Locally", "恢复到本地")) {
                        restoreYouTubeImport(imported)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(10)
                .background(BrandColors.surface,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

private enum PlaylistDeletionTarget {
    case playlist(Playlist)
    case youTubeImport(YouTubeImport)

    var title: String {
        switch self {
        case .playlist(let playlist):
            return tr("Delete \(playlist.name)?", "删除 \(playlist.name)？")
        case .youTubeImport(let imported):
            return tr("Delete \(imported.title)?", "删除 \(imported.title)？")
        }
    }

    var message: String {
        switch self {
        case .playlist:
            return tr("The playlist will be removed from this Mac. You can undo it while this screen remains open.",
                      "歌单会从此 Mac 移除；保持此页面打开时可撤销。")
        case .youTubeImport:
            return tr("The local import moves to Recently Deleted for 30 days. YouTube is not changed.",
                      "本地导入会移入“最近删除”并保留 30 天；YouTube 不会被修改。")
        }
    }
}

struct PlaylistAddChoiceSheet: View {
    let onNew: () -> Void
    let onImport: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(tr("Add Playlist", "添加歌单"))
                    .font(.title2.weight(.semibold))
                Spacer()
                ChromeIconButton(systemName: "xmark",
                                 help: tr("Close", "关闭"),
                                 accessibility: tr("Close", "关闭")) {
                    dismiss()
                }
            }
            choiceButton(
                title: tr("New Playlist", "新建歌单"),
                subtitle: tr("Create an empty Muses playlist", "创建一个空的 Muses 歌单"),
                systemName: "plus.square.on.square",
                action: onNew
            )
            choiceButton(
                title: tr("Import YouTube Playlist", "导入 YouTube 歌单"),
                subtitle: tr("Paste a YouTube or YouTube Music playlist link", "粘贴 YouTube 或 YouTube Music 歌单链接"),
                systemName: "square.and.arrow.down",
                action: onImport
            )
        }
        .padding(20)
        .frame(width: 420)
        .musesFloatingChrome(cornerRadius: 18)
    }

    private func choiceButton(title: String, subtitle: String,
                              systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemName)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 30)
                    .foregroundStyle(BrandColors.magenta)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(BrandColors.textPrimary)
                    Text(subtitle).font(.caption).foregroundStyle(BrandColors.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(BrandColors.textSecondary)
            }
            .padding(14)
            .background(BrandColors.surface,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Shared create-playlist prompt used by the sidebar, Playlists overview, and track menus.
struct NewPlaylistSheet: View {
    @Binding var isPresented: Bool
    var onCreate: (String) -> Void
    @State private var name = ""

    var body: some View {
        VStack(spacing: 16) {
            Text(tr("New Playlist", "新建歌单")).font(.headline)
            TextField(tr("Playlist name", "歌单名称"), text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button(tr("Cancel", "取消")) {
                    isPresented = false
                    name = ""
                }
                Button(tr("Create", "创建")) {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { onCreate(trimmed) }
                    isPresented = false
                    name = ""
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColors.magenta)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 320)
        .musesFloatingChrome(cornerRadius: 16)
    }
}
