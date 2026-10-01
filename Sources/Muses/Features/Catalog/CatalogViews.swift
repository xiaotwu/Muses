import SwiftData
import SwiftUI

private struct UnresolvedCatalogNotice: View {
    let count: Int
    var body: some View {
        Label(tr("\(count) songs do not yet have confirmed artist or album pages. They remain available in Songs.",
                 "\(count) 首歌曲尚无可确认的艺人或专辑页面，仍可在「歌曲」中播放。",
                 zhHant: "\(count) 首歌曲尚無可確認的藝人或專輯頁面，仍可在「歌曲」中播放。"),
              systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Releases (Albums) Overview

enum ReleaseFilter: String, CaseIterable, Identifiable {
    case all
    case albums
    case singles
    var id: Self { self }

    var localizedTitle: String {
        switch self {
        case .all: return tr("All", "全部")
        case .albums: return tr("Albums", "专辑")
        case .singles: return tr("Singles & EPs", "单曲与 EP")
        }
    }
}

enum ReleaseSort: String, CaseIterable, Identifiable {
    case title
    case artist
    case year
    var id: Self { self }

    var localizedTitle: String {
        switch self {
        case .title: return tr("Title A–Z", "标题 A–Z")
        case .artist: return tr("Artist", "艺人")
        case .year: return tr("Release Year", "发行年份")
        }
    }
}

struct CatalogReleasesView: View {
    @Binding var selection: CatalogReleaseProjection?
    @Environment(YouTubeCatalogService.self) private var catalog
    @Environment(PlaybackService.self) private var playback
    @State private var releases: [CatalogReleaseProjection] = []
    @State private var unresolvedCount = 0
    @State private var loading = true
    @State private var isRefreshing = false
    @State private var refreshFailures = 0
    @State private var searchQuery = ""
    @State private var filter: ReleaseFilter = .all
    @State private var sort: ReleaseSort = .title

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 24)]

    private var filteredReleases: [CatalogReleaseProjection] {
        var list = releases

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            list = list.filter {
                $0.title.lowercased().contains(query) || $0.artistName.lowercased().contains(query)
            }
        }

        switch filter {
        case .all:
            break
        case .albums:
            list = list.filter { $0.kind == .album || $0.kind == .unknown }
        case .singles:
            list = list.filter { $0.kind == .single || $0.kind == .ep }
        }

        switch sort {
        case .title:
            list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist:
            list.sort { $0.artistName.localizedStandardCompare($1.artistName) == .orderedAscending }
        case .year:
            list.sort { ($0.year ?? 0) > ($1.year ?? 0) }
        }

        return list
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader
                filterBar
                if isRefreshing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(tr("Refreshing catalog…", "正在刷新目录…", zhHant: "正在重新整理目錄…"))
                            .foregroundStyle(.secondary)
                    }
                } else if refreshFailures > 0 {
                    Text(tr("Some online metadata could not be refreshed. Cached items remain available; use Refresh to retry.",
                            "部分在线信息暂时无法刷新，缓存内容仍然可用；可点击刷新重试。", zhHant: "部分線上資訊暫時無法重新整理，快取內容仍然可用；可點擊重新整理重試。"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if unresolvedCount > 0 { UnresolvedCatalogNotice(count: unresolvedCount) }

                if loading && releases.isEmpty {
                    CatalogLoadingGrid()
                } else if releases.isEmpty {
                    CatalogEmptyState(
                        icon: "square.stack",
                        title: tr("No albums yet", "还没有专辑"),
                        subtitle: tr(
                            "Import an official YouTube Music album to establish its catalog identity.",
                            "导入官方 YouTube Music 专辑以确认其目录身份。",
                            zhHant: "匯入官方 YouTube Music 專輯以確認其目錄身分。"
                        ),
                        onRefresh: refresh
                    )
                } else if filteredReleases.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundStyle(BrandColors.textSecondary)
                        Text(tr("No matching albums", "没有找到匹配的专辑"))
                            .font(.headline)
                            .foregroundStyle(BrandColors.textPrimary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(filteredReleases) { release in
                            AlbumObjectView(
                                title: release.title,
                                subtitle: releaseSubtitle(release),
                                artwork: releaseArtwork(release),
                                size: 200,
                                style: .heroCard(tag: release.kind == .single ? tr("SINGLE", "单曲") : (release.kind == .ep ? tr("EP", "EP") : tr("ALBUM", "专辑"))),
                                showsHoverPlay: !release.tracks.isEmpty,
                                onSelect: { selection = release },
                                onPlay: { play(release.tracks, from: .album) }
                            )
                            .overlay(alignment: .topTrailing) {
                                CatalogStateBadge(state: release.cacheState)
                                    .padding(7)
                            }
                            .catalogReleaseContextMenu(
                                release: release,
                                onOpen: { selection = release },
                                onPlay: { play(release.tracks, from: .album) },
                                onShuffle: { play(release.tracks.shuffled(), from: .album) }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, AppleMusicTokens.contentPaddingX)
            .padding(.top, AppleMusicSpacing.browseTitleTop)
            .padding(.bottom, AppleMusicTokens.scrollBottomInset)
        }
        .background(BrowseBackground())
        .task(id: catalog.revision) { load() }
    }

    private var pageHeader: some View {
        HStack(alignment: .center) {
            Text(tr("Albums", "专辑"))
                .font(MusesTypography.pageTitle)
                .foregroundStyle(BrandColors.heading)
            Spacer()
            ChromeIconButton(
                systemName: "arrow.clockwise",
                help: tr("Refresh Catalog", "刷新目录"),
                accessibility: tr("Refresh Catalog", "刷新目录"),
                action: refresh
            )
            .disabled(isRefreshing)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(BrandColors.textSecondary)
                TextField(tr("Filter albums…", "过滤专辑…"), text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(BrandColors.textSecondary)
                    }
                    .buttonStyle(.fullAreaPlain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: 240)
            .background(BrandColors.surface, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(BrandColors.hairline, lineWidth: 1)
            )

            // Category filter chips
            HStack(spacing: 6) {
                ForEach(ReleaseFilter.allCases) { item in
                    Button {
                        filter = item
                    } label: {
                        Text(item.localizedTitle)
                            .font(.system(size: 12, weight: filter == item ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                filter == item
                                ? BrandColors.accent
                                : BrandColors.surface,
                                in: Capsule()
                            )
                            .foregroundStyle(filter == item ? .white : BrandColors.textPrimary)
                    }
                    .buttonStyle(.fullAreaPlain)
                }
            }

            Spacer()

            // Sort Menu
            ChromeIconMenu(systemName: "arrow.up.arrow.down", title: tr("Sort", "排序")) {
                ForEach(ReleaseSort.allCases) { s in
                    Button {
                        sort = s
                    } label: {
                        HStack {
                            Text(s.localizedTitle)
                            if sort == s {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            .help(sort.localizedTitle)
        }
    }

    private func load() {
        releases = catalog.releases()
        unresolvedCount = catalog.unresolvedCounts().releases
        loading = false
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        loading = true
        refreshFailures = 0
        Task {
            refreshFailures = await catalog.refreshCatalog()
            load()
            isRefreshing = false
        }
    }

    private func releaseSubtitle(_ release: CatalogReleaseProjection) -> String {
        let year = release.year.map(String.init) ?? ""
        return [release.artistName, year].filter { !$0.isEmpty }.joined(separator: " • ")
    }

    private func releaseArtwork(_ release: CatalogReleaseProjection) -> ArtworkSource {
        ArtworkSource.resolve(remoteURL: release.artworkURL,
                              youTubeId: release.tracks.first?.youTubeId)
    }

    private func play(_ tracks: [TrackSnapshot], from source: QueueSource) {
        guard let first = tracks.first else { return }
        playback.playTrack(first, context: tracks, from: source)
    }
}

// MARK: - Album Detail View

struct CatalogReleaseDetailView: View {
    let release: CatalogReleaseProjection
    @Binding var selection: CatalogReleaseProjection?
    @Environment(PlaybackService.self) private var playback
    @Environment(YouTubeCatalogService.self) private var catalog
    @Environment(LibraryService.self) private var library
    @Query(sort: \Playlist.name) private var playlists: [Playlist]

    @State private var onlineTask: Task<Void, Never>?
    @State private var refreshedRelease: CatalogReleaseProjection?
    private var currentRelease: CatalogReleaseProjection { refreshedRelease ?? release }

    @State private var onlineTracks: [YTDlpBridge.YTDlpPlaylistEntry] = []
    @State private var isLoadingOnlineTracks = false
    @State private var onlineTracksError: String?
    @State private var hasCheckedOnline = false

    private var localVideoIDs: Set<String> {
        Set(currentRelease.tracks.map(\.youTubeId))
    }

    private var totalDurationSeconds: Double {
        currentRelease.tracks.reduce(0) { $0 + $1.durationSeconds }
    }

    private var formattedDuration: String {
        let minutes = Int(totalDurationSeconds) / 60
        if minutes >= 60 {
            let hours = minutes / 60
            let remMin = minutes % 60
            return tr("\(hours) hr \(remMin) min", "\(hours) 小时 \(remMin) 分钟", zhHant: "\(hours) 小時 \(remMin) 分鐘")
        }
        return tr("\(minutes) minutes", "\(minutes) 分钟", zhHant: "\(minutes) 分鐘")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                topNavigationBar
                heroBanner
                tracklistSection
                if hasCheckedOnline {
                    onlineComparisonSection
                }
            }
            .padding(.horizontal, AppleMusicTokens.contentPaddingX)
            .padding(.top, 16)
            .padding(.bottom, AppleMusicTokens.scrollBottomInset)
        }
        .background(BrowseBackground())
        .onDisappear { onlineTask?.cancel() }
        .task(id: catalog.revision) {
            refreshedRelease = catalog.release(byStableID: release.stableID)
        }
    }

    private var topNavigationBar: some View {
        HStack(spacing: 8) {
            Text(tr("Albums", "专辑"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(BrandColors.textSecondary)
            Spacer()
        }
    }

    private var heroBanner: some View {
        HStack(alignment: .top, spacing: 28) {
            // Artwork
            ArtworkView(
                source: ArtworkSource.resolve(
                    remoteURL: currentRelease.artworkURL,
                    youTubeId: currentRelease.tracks.first?.youTubeId
                ),
                cornerRadius: 14,
                glyphSize: 64,
                targetSize: 220,
                targetHeight: 220
            )
            .frame(width: 220, height: 220)
            .shadow(color: Color.black.opacity(0.35), radius: 16, y: 8)

            // Metadata & Controls
            VStack(alignment: .leading, spacing: 10) {
                Text(currentRelease.kind == .single ? tr("SINGLE", "单曲") : (currentRelease.kind == .ep ? tr("EP", "EP") : tr("ALBUM", "专辑")))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(BrandColors.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(BrandColors.accent.opacity(0.12), in: Capsule())

                Text(currentRelease.title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(2)

                Button {
                    NotificationCenter.default.post(
                        name: .musesNavigateToArtist,
                        object: currentRelease.artistStableID ?? currentRelease.artistName
                    )
                } label: {
                    HStack(spacing: 4) {
                        Text(currentRelease.artistName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(BrandColors.accent)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(BrandColors.accent.opacity(0.8))
                    }
                }
                .buttonStyle(.fullAreaPlain)

                HStack(spacing: 6) {
                    if let year = currentRelease.year {
                        Text("\(year)")
                        Text("•")
                    }
                    Text(tr("\(currentRelease.tracks.count) songs", "\(currentRelease.tracks.count) 首歌曲", zhHant: "\(currentRelease.tracks.count) 首歌曲"))
                    if totalDurationSeconds > 0 {
                        Text("•")
                        Text(formattedDuration)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(BrandColors.textSecondary)

                Spacer()

                // Actions row
                HStack(spacing: 12) {
                    Button(action: playAll) {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 13, weight: .bold))
                            Text(tr("Play", "播放"))
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(BrandColors.accent, in: Capsule())
                    }
                    .buttonStyle(.fullAreaPlain)

                    Button(action: shuffle) {
                        HStack(spacing: 6) {
                            Image(systemName: "shuffle")
                                .font(.system(size: 13, weight: .semibold))
                            Text(tr("Shuffle", "随机播放"))
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(BrandColors.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(BrandColors.surface, in: Capsule())
                        .overlay(Capsule().stroke(BrandColors.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.fullAreaPlain)

                    Button(action: checkOnlineTracklist) {
                        HStack(spacing: 6) {
                            if isLoadingOnlineTracks {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "cloud.fill")
                                    .font(.system(size: 12))
                            }
                            Text(tr("Online Tracklist", "在线曲目单"))
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(BrandColors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(BrandColors.surface, in: Capsule())
                        .overlay(Capsule().stroke(BrandColors.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.fullAreaPlain)

                    if let url = YouTubeCatalogLink.releaseURL(stableID: currentRelease.stableID) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            YouTubeMark(size: 14)
                                .padding(8)
                                .background(BrandColors.surface, in: Circle())
                                .overlay(Circle().stroke(BrandColors.hairline, lineWidth: 1))
                        }
                        .buttonStyle(.fullAreaPlain)
                        .help(tr("Open in YouTube Music", "在 YouTube Music 打开"))
                    }
                }
            }
            .frame(height: 220)

            Spacer()
        }
    }

    private var tracklistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Tracks in Library", "资料库中的曲目"))
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(BrandColors.textPrimary)

            if currentRelease.tracks.isEmpty {
                Text(tr("No tracks from this album are saved in your library. Open the online tracklist to browse its songs.",
                        "资料库中暂未保存此专辑的曲目，可打开在线曲目单浏览歌曲。", zhHant: "資料庫中暫未儲存此專輯的曲目，可開啟線上曲目單瀏覽歌曲。"))
                    .foregroundStyle(.secondary)
            }
            LazyVStack(spacing: 1) {
                ForEach(Array(currentRelease.tracks.enumerated()), id: \.element.id) { index, track in
                    trackRow(index: index + 1, snapshot: track)
                }
            }
            .background(BrandColors.surface.opacity(0.5), in: Capsule())
        }
    }

    private func trackRow(index: Int, snapshot: TrackSnapshot) -> some View {
        let isCurrent = playback.state.track?.id == snapshot.id
        return HStack(spacing: 12) {
            Text("\(index)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BrandColors.textSecondary)
                .frame(width: 24, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.title)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? BrandColors.accent : BrandColors.textPrimary)
                    .lineLimit(1)
                Text(snapshot.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(BrandColors.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(formatDuration(snapshot.durationSeconds))
                .font(.system(size: 12))
                .foregroundStyle(BrandColors.textSecondary)

            Button {
                playback.playTrack(snapshot, context: currentRelease.tracks, from: .album)
            } label: {
                let playing = isCurrent && playback.state.isPlaying
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(BrandColors.textPrimary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.fullAreaPlain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            playback.playTrack(snapshot, context: currentRelease.tracks, from: .album)
        }
        .trackContextMenu(
            snapshot: snapshot,
            playlists: playlists,
            onPlay: { playback.playTrack(snapshot, context: currentRelease.tracks, from: .album) }
        )
    }

    private var onlineComparisonSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(tr("Official Tracklist", "官方曲目单"))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(BrandColors.textPrimary)

                Spacer()

                let missing = onlineTracks.filter { !localVideoIDs.contains($0.id) }
                if !isLoadingOnlineTracks && onlineTracksError == nil && !missing.isEmpty {
                    Button {
                        importMissingTracks(missing)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus.circle.fill")
                            Text(tr("Import \(missing.count) Missing Tracks", "导入 \(missing.count) 首缺失曲目", zhHant: "導入 \(missing.count) 首缺失曲目"))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(BrandColors.accent, in: Capsule())
                    }
                    .buttonStyle(.fullAreaPlain)
                }
            }

            if isLoadingOnlineTracks {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(tr("Loading official tracklist…", "正在载入官方曲目单…", zhHant: "正在載入官方曲目單…"))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)
            } else if let onlineTracksError {
                Text(tr("The online tracklist could not be refreshed. Your library tracks remain available.",
                        "在线曲目单暂时无法刷新，资料库中的曲目仍然可用。", zhHant: "線上曲目單暫時無法重新整理，資料庫中的曲目仍然可用。"))
                    .foregroundStyle(.secondary)
                Text(onlineTracksError).font(.caption).foregroundStyle(.secondary)
                Button(tr("Retry", "重试", zhHant: "重試"), systemImage: "arrow.clockwise", action: checkOnlineTracklist)
                    .labelStyle(ActionIconLabelStyle())
                    .help(tr("Retry", "重试", zhHant: "重試"))
            } else if onlineTracks.isEmpty {
                Text(tr("No online tracks are available for this album.", "此专辑暂无可用的在线曲目。", zhHant: "此專輯暫無可用的線上曲目。"))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            }
            LazyVStack(spacing: 1) {
                ForEach(Array(onlineTracks.enumerated()), id: \.element.id) { idx, entry in
                    let inLibrary = localVideoIDs.contains(entry.id)
                    HStack(spacing: 12) {
                        Text("\(idx + 1)")
                            .font(.system(size: 12))
                            .foregroundStyle(BrandColors.textSecondary)
                            .frame(width: 24, alignment: .trailing)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .font(.system(size: 13))
                                .foregroundStyle(BrandColors.textPrimary)
                                .lineLimit(1)
                            Text(entry.uploader ?? currentRelease.artistName)
                                .font(.system(size: 11))
                                .foregroundStyle(BrandColors.textSecondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        if inLibrary {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark")
                                Text(tr("In Library", "已在库中"))
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(BrandColors.textSecondary)
                        } else {
                            Button {
                                importSingleTrack(entry, order: idx)
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "plus")
                                    Text(tr("Add", "添加"))
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(BrandColors.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(BrandColors.accent.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.fullAreaPlain)
                        }

                        Button {
                            playOnlineTrack(entry)
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(BrandColors.accent)
                        }
                        .buttonStyle(.fullAreaPlain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
            .background(BrandColors.surface.opacity(0.5), in: Capsule())
        }
    }

    private func playAll() {
        guard let first = currentRelease.tracks.first else { return }
        playback.playTrack(first, context: currentRelease.tracks, from: .album)
    }

    private func shuffle() {
        let tracks = currentRelease.tracks.shuffled()
        guard let first = tracks.first else { return }
        playback.playTrack(first, context: tracks, from: .album)
    }

    private func checkOnlineTracklist() {
        guard !isLoadingOnlineTracks else { return }
        onlineTracksError = nil
        isLoadingOnlineTracks = true
        hasCheckedOnline = true
        onlineTask = Task {
            do {
                let entries = try await catalog.fetchAlbumOnlineTracks(release: currentRelease, forceRefresh: true)
                guard !Task.isCancelled else {
                    isLoadingOnlineTracks = false
                    return
                }
                await MainActor.run {
                    self.onlineTracks = entries
                    self.isLoadingOnlineTracks = false
                }
            } catch is CancellationError {
                isLoadingOnlineTracks = false
            } catch {
                await MainActor.run {
                    self.onlineTracksError = error.localizedDescription
                    self.isLoadingOnlineTracks = false
                }
            }
        }
    }

    private func importMissingTracks(_ missing: [YTDlpBridge.YTDlpPlaylistEntry]) {
        do {
            for entry in missing {
                try catalog.importOnlineTrack(
                    entry: entry,
                    releaseStableID: currentRelease.stableID,
                    order: onlineTracks.firstIndex(where: { $0.id == entry.id }),
                    albumTitle: currentRelease.title,
                    artistName: currentRelease.artistName
                )
            }
        } catch {
            onlineTracksError = error.localizedDescription
        }
    }

    private func importSingleTrack(_ entry: YTDlpBridge.YTDlpPlaylistEntry, order: Int) {
        do {
            try catalog.importOnlineTrack(
                entry: entry,
                releaseStableID: currentRelease.stableID,
                order: order,
                albumTitle: currentRelease.title,
                artistName: currentRelease.artistName
            )
        } catch {
            onlineTracksError = error.localizedDescription
        }
    }

    private func playOnlineTrack(_ entry: YTDlpBridge.YTDlpPlaylistEntry) {
        Task {
            do {
                let release = currentRelease
                let snapshot = try catalog.importOnlineTrack(
                    entry: entry, releaseStableID: release.stableID,
                    order: onlineTracks.firstIndex(where: { $0.id == entry.id }),
                    albumTitle: release.title, artistName: release.artistName,
                    saveToLibrary: false)
                let context = TrackSnapshot.playbackContext(
                    playing: snapshot, youTubeEntries: onlineTracks)
                playback.playTrack(snapshot, context: context, from: .album)
            } catch {
                onlineTracksError = error.localizedDescription
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        let m = s / 60
        let sec = s % 60
        return String(format: "%d:%02d", m, sec)
    }
}

// MARK: - Artists Overview

enum ArtistSort: String, CaseIterable, Identifiable {
    case name
    case songCount
    var id: Self { self }

    var localizedTitle: String {
        switch self {
        case .name: return tr("Name A–Z", "姓名 A–Z")
        case .songCount: return tr("Most Songs", "歌曲数量")
        }
    }
}

struct CatalogArtistsView: View {
    @Binding var selection: CatalogArtistProjection?
    @Environment(YouTubeCatalogService.self) private var catalog
    @Environment(PlaybackService.self) private var playback
    @State private var artists: [CatalogArtistProjection] = []
    @State private var unresolvedCount = 0
    @State private var loading = true
    @State private var isRefreshing = false
    @State private var refreshFailures = 0
    @State private var searchQuery = ""
    @State private var sort: ArtistSort = .name

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 22)]

    private var filteredArtists: [CatalogArtistProjection] {
        var list = artists
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            list = list.filter { $0.name.lowercased().contains(query) }
        }
        switch sort {
        case .name:
            list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .songCount:
            list.sort { $0.tracks.count > $1.tracks.count }
        }
        return list
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader
                filterBar
                if isRefreshing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(tr("Refreshing catalog…", "正在刷新目录…", zhHant: "正在重新整理目錄…"))
                            .foregroundStyle(.secondary)
                    }
                } else if refreshFailures > 0 {
                    Text(tr("Some online metadata could not be refreshed. Cached items remain available; use Refresh to retry.",
                            "部分在线信息暂时无法刷新，缓存内容仍然可用；可点击刷新重试。", zhHant: "部分線上資訊暫時無法重新整理，快取內容仍然可用；可點擊重新整理重試。"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if unresolvedCount > 0 { UnresolvedCatalogNotice(count: unresolvedCount) }

                if loading && artists.isEmpty {
                    CatalogLoadingGrid()
                } else if artists.isEmpty {
                    CatalogEmptyState(
                        icon: "person.2",
                        title: tr("No artists yet", "还没有艺术家"),
                        subtitle: tr(
                            "Artist profiles appear when your songs have a confirmed artist page.",
                            "歌曲有可确认的艺人主页时，会在此显示。",
                            zhHant: "歌曲有可確認的藝人主頁時，會在此顯示。"
                        ),
                        onRefresh: refresh
                    )
                } else if filteredArtists.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundStyle(BrandColors.textSecondary)
                        Text(tr("No matching artists", "没有找到匹配的艺术家"))
                            .font(.headline)
                            .foregroundStyle(BrandColors.textPrimary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(filteredArtists) { artist in
                            ArtistObjectView(
                                name: artist.name,
                                detail: tr("\(artist.tracks.count) songs", "\(artist.tracks.count) 首歌曲", zhHant: "\(artist.tracks.count) 首歌曲"),
                                artwork: artistArtwork(artist),
                                size: 190,
                                showsHoverPlay: !artist.tracks.isEmpty,
                                onSelect: { selection = artist },
                                onPlay: { play(artist.tracks) }
                            )
                            .overlay(alignment: .topTrailing) {
                                CatalogStateBadge(state: artist.cacheState)
                                    .padding(7)
                            }
                            .catalogArtistContextMenu(
                                artist: artist,
                                onOpen: { selection = artist },
                                onPlay: { play(artist.tracks) },
                                onShuffle: { play(artist.tracks.shuffled()) }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, AppleMusicTokens.contentPaddingX)
            .padding(.top, AppleMusicSpacing.browseTitleTop)
            .padding(.bottom, AppleMusicTokens.scrollBottomInset)
        }
        .background(BrowseBackground())
        .task(id: catalog.revision) { load() }
    }

    private var pageHeader: some View {
        HStack(alignment: .center) {
            Text(tr("Artists", "艺术家"))
                .font(MusesTypography.pageTitle)
                .foregroundStyle(BrandColors.heading)
            Spacer()
            ChromeIconButton(
                systemName: "arrow.clockwise",
                help: tr("Refresh Catalog", "刷新目录"),
                accessibility: tr("Refresh Catalog", "刷新目录"),
                action: refresh
            )
            .disabled(isRefreshing)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(BrandColors.textSecondary)
                TextField(tr("Filter artists…", "过滤艺术家…"), text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(BrandColors.textSecondary)
                    }
                    .buttonStyle(.fullAreaPlain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: 240)
            .background(BrandColors.surface, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(BrandColors.hairline, lineWidth: 1)
            )

            Spacer()

            ChromeIconMenu(systemName: "arrow.up.arrow.down", title: tr("Sort", "排序")) {
                ForEach(ArtistSort.allCases) { s in
                    Button {
                        sort = s
                    } label: {
                        HStack {
                            Text(s.localizedTitle)
                            if sort == s {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            .help(sort.localizedTitle)
        }
    }

    private func load() {
        artists = catalog.artists()
        unresolvedCount = catalog.unresolvedCounts().artists
        loading = false
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        loading = true
        refreshFailures = 0
        Task {
            refreshFailures = await catalog.refreshCatalog()
            load()
            isRefreshing = false
        }
    }

    private func artistArtwork(_ artist: CatalogArtistProjection) -> ArtworkSource {
        ArtworkSource.resolve(remoteURL: artist.artworkURL,
                              youTubeId: artist.tracks.first?.youTubeId)
    }

    private func play(_ tracks: [TrackSnapshot]) {
        guard let first = tracks.first else { return }
        playback.playTrack(first, context: tracks, from: .artist)
    }
}

// MARK: - Artist Detail View

struct CatalogArtistDetailView: View {
    let artist: CatalogArtistProjection
    @Binding var selection: CatalogArtistProjection?
    @Environment(PlaybackService.self) private var playback
    @Environment(YouTubeCatalogService.self) private var catalog
    @Environment(LibraryService.self) private var library
    @Query(sort: \Playlist.name) private var playlists: [Playlist]

    @State private var onlineTask: Task<Void, Never>?
    @State private var refreshedArtist: CatalogArtistProjection?
    private var currentArtist: CatalogArtistProjection { refreshedArtist ?? artist }

    @State private var discography: ArtistOnlineDiscography?
    @State private var isLoadingOnline = false
    @State private var onlineError: String?
    @State private var hasExpandedOnline = false

    private var orderedTracks: [TrackSnapshot] {
        currentArtist.tracks.sorted {
            let result = $0.title.localizedStandardCompare($1.title)
            if result != .orderedSame { return result == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                topNavigationBar
                heroBanner

                // Section 1: Library Tracks
                libraryTracksSection

                // Section 2: Library Albums (if any)
                if !currentArtist.releases.isEmpty {
                    libraryAlbumsSection
                }

                // Section 3: Online Discovery
                onlineDiscoverySection
            }
            .padding(.horizontal, AppleMusicTokens.contentPaddingX)
            .padding(.top, 16)
            .padding(.bottom, AppleMusicTokens.scrollBottomInset)
        }
        .background(BrowseBackground())
        .onDisappear { onlineTask?.cancel() }
        .task(id: catalog.revision) {
            refreshedArtist = catalog.artist(byStableID: artist.stableID)
        }
    }

    private var topNavigationBar: some View {
        HStack(spacing: 8) {
            Text(tr("Artists", "艺术家"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(BrandColors.textSecondary)
            Spacer()
        }
    }

    private var heroBanner: some View {
        HStack(spacing: 24) {
            // Circular avatar
            ArtworkView(
                source: ArtworkSource.resolve(
                    remoteURL: currentArtist.artworkURL,
                    youTubeId: currentArtist.tracks.first?.youTubeId
                ),
                cornerRadius: 70,
                glyphSize: 50,
                targetSize: 140,
                targetHeight: 140
            )
            .frame(width: 140, height: 140)
            .clipShape(Circle())
            .shadow(color: Color.black.opacity(0.35), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: 8) {
                Text(currentArtist.name)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(BrandColors.textPrimary)

                HStack(spacing: 8) {
                    Text(tr("\(currentArtist.tracks.count) songs in library", "\(currentArtist.tracks.count) 首歌曲在资料库", zhHant: "\(currentArtist.tracks.count) 首歌曲在資料庫"))
                    if !currentArtist.releases.isEmpty {
                        Text("•")
                        Text(tr("\(currentArtist.releases.count) albums", "\(currentArtist.releases.count) 张专辑", zhHant: "\(currentArtist.releases.count) 張專輯"))
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(BrandColors.textSecondary)

                HStack(spacing: 12) {
                    Button(action: playAll) {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 13, weight: .bold))
                            Text(tr("Play", "播放"))
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(BrandColors.accent, in: Capsule())
                    }
                    .buttonStyle(.fullAreaPlain)

                    Button(action: shuffle) {
                        HStack(spacing: 6) {
                            Image(systemName: "shuffle")
                                .font(.system(size: 13, weight: .semibold))
                            Text(tr("Shuffle", "随机播放"))
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(BrandColors.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(BrandColors.surface, in: Capsule())
                        .overlay(Capsule().stroke(BrandColors.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.fullAreaPlain)

                    Button(action: toggleOnlineDiscovery) {
                        HStack(spacing: 6) {
                            if isLoadingOnline {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 12))
                            }
                            Text(hasExpandedOnline ? tr("Refresh Online", "刷新在线") : tr("Explore Online", "在线探索"))
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(BrandColors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(BrandColors.surface, in: Capsule())
                        .overlay(Capsule().stroke(BrandColors.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.fullAreaPlain)

                    if let url = YouTubeCatalogLink.artistURL(stableID: currentArtist.stableID) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            YouTubeMark(size: 14)
                                .padding(8)
                                .background(BrandColors.surface, in: Circle())
                                .overlay(Circle().stroke(BrandColors.hairline, lineWidth: 1))
                        }
                        .buttonStyle(.fullAreaPlain)
                        .help(tr("Open in YouTube Music", "在 YouTube Music 打开"))
                    }
                }
                .padding(.top, 4)
            }

            Spacer()
        }
    }

    private var libraryTracksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Songs in Library", "资料库中的歌曲"))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(BrandColors.textPrimary)

            if orderedTracks.isEmpty {
                Text(tr("No songs from this artist are saved in your library. Explore online to find their music.",
                        "资料库中暂未保存此艺人的歌曲，可通过在线探索查找作品。", zhHant: "資料庫中暫未儲存此藝人的歌曲，可透過線上探索尋找作品。"))
                    .foregroundStyle(.secondary)
            }
            LazyVStack(spacing: 1) {
                ForEach(Array(orderedTracks.enumerated()), id: \.element.id) { index, track in
                    let isCurrent = playback.state.track?.id == track.id
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.system(size: 12))
                            .foregroundStyle(BrandColors.textSecondary)
                            .frame(width: 24, alignment: .trailing)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                                .foregroundStyle(isCurrent ? BrandColors.accent : BrandColors.textPrimary)
                                .lineLimit(1)
                            if let album = track.albumTitle {
                                Text(album)
                                    .font(.system(size: 11))
                                    .foregroundStyle(BrandColors.textSecondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        Button {
                            playback.playTrack(track, context: orderedTracks, from: .artist)
                        } label: {
                            let playing = isCurrent && playback.state.isPlaying
                            Image(systemName: playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(BrandColors.textPrimary)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.fullAreaPlain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        playback.playTrack(track, context: orderedTracks, from: .artist)
                    }
                    .trackContextMenu(
                        snapshot: track,
                        playlists: playlists,
                        onPlay: { playback.playTrack(track, context: orderedTracks, from: .artist) }
                    )
                }
            }
            .background(BrandColors.surface.opacity(0.5), in: Capsule())
        }
    }

    private var libraryAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Albums in Library", "资料库中的专辑"))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(BrandColors.textPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 18) {
                    ForEach(currentArtist.releases) { release in
                        AlbumObjectView(
                            title: release.title,
                            subtitle: release.year.map(String.init) ?? "",
                            artwork: ArtworkSource.resolve(remoteURL: release.artworkURL, youTubeId: release.tracks.first?.youTubeId),
                            size: 160,
                            showsHoverPlay: !release.tracks.isEmpty,
                            onSelect: {
                                NotificationCenter.default.post(
                                    name: .musesNavigateToRelease,
                                    object: release
                                )
                            },
                            onPlay: {
                                guard let first = release.tracks.first else { return }
                                playback.playTrack(first, context: release.tracks, from: .album)
                            }
                        )
                    }
                }
            }
        }
    }

    private var onlineDiscoverySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if hasExpandedOnline {
                Text(tr("Online Discovery", "在线探索"))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(BrandColors.textPrimary)

                if isLoadingOnline {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(tr("Loading artist discography…", "正在载入艺术家作品…"))
                            .font(.subheadline)
                            .foregroundStyle(BrandColors.textSecondary)
                    }
                    .padding(.vertical, 20)
                }
                if let onlineError {
                    Text(onlineError).foregroundStyle(.secondary)
                    Button(tr("Retry", "重试", zhHant: "重試"), systemImage: "arrow.clockwise", action: toggleOnlineDiscovery)
                        .labelStyle(ActionIconLabelStyle())
                        .help(tr("Retry", "重试", zhHant: "重試"))
                }
                if let disco = discography {
                    // Popular Songs
                    if disco.isEmpty && !isLoadingOnline && onlineError == nil {
                        Text(tr("No online releases or songs are available for this channel.", "此频道暂无可用的在线作品或歌曲。", zhHant: "此頻道暫無可用的線上作品或歌曲。"))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 16)
                    }
                    if !disco.topTracks.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(tr("From this YouTube channel", "来自此 YouTube 频道", zhHant: "來自此 YouTube 頻道"))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(BrandColors.textPrimary)

                            LazyVStack(spacing: 1) {
                                ForEach(Array(disco.topTracks.prefix(8).enumerated()), id: \.element.id) { idx, entry in
                                    onlineTrackRow(index: idx + 1, entry: entry)
                                }
                            }
                            .background(BrandColors.surface.opacity(0.5), in: Capsule())
                        }
                    }

                    // Online Albums
                    if !disco.albums.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(tr("Official Albums", "官方专辑"))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(BrandColors.textPrimary)

                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 16) {
                                    ForEach(disco.albums) { release in
                                        onlineReleaseCard(release)
                                    }
                                }
                            }
                        }
                    }

                    // Online Singles & EPs
                    if !disco.singlesAndEPs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(tr("Singles & EPs", "单曲与 EP"))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(BrandColors.textPrimary)

                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 16) {
                                    ForEach(disco.singlesAndEPs) { release in
                                        onlineReleaseCard(release)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func onlineTrackRow(index: Int, entry: YTDlpBridge.YTDlpPlaylistEntry) -> some View {
        HStack(spacing: 12) {
            Text("\(index)")
                .font(.system(size: 12))
                .foregroundStyle(BrandColors.textSecondary)
                .frame(width: 24, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 13))
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(1)
                Text(entry.uploader ?? currentArtist.name)
                    .font(.system(size: 11))
                    .foregroundStyle(BrandColors.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                importTrack(entry)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus")
                    Text(tr("Add", "添加"))
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(BrandColors.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(BrandColors.accent.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.fullAreaPlain)

            Button {
                playOnlineTrack(entry)
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(BrandColors.accent)
            }
            .buttonStyle(.fullAreaPlain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func onlineReleaseCard(_ release: OnlineReleaseItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(
                source: ArtworkSource.resolve(
                    remoteURL: release.artworkURL, youTubeId: nil),
                cornerRadius: 10,
                glyphSize: 32,
                targetSize: 140,
                targetHeight: 140
            )
            .frame(width: 140, height: 140)
            .shadow(color: Color.black.opacity(0.2), radius: 6, y: 3)

            Text(release.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BrandColors.textPrimary)
                .lineLimit(1)

            if let year = release.year {
                Text("\(year)")
                    .font(.system(size: 11))
                    .foregroundStyle(BrandColors.textSecondary)
            }

            Button {
                importOnlineAlbum(release)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus")
                    Text(tr("Import", "导入"))
                }
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(BrandColors.accent, in: Capsule())
            }
            .buttonStyle(.fullAreaPlain)
        }
        .frame(width: 140)
    }

    private func playAll() {
        guard let first = orderedTracks.first else { return }
        playback.playTrack(first, context: orderedTracks, from: .artist)
    }

    private func shuffle() {
        let shuffled = orderedTracks.shuffled()
        guard let first = shuffled.first else { return }
        playback.playTrack(first, context: shuffled, from: .artist)
    }

    private func toggleOnlineDiscovery() {
        guard !isLoadingOnline else { return }
        onlineError = nil
        hasExpandedOnline = true
        isLoadingOnline = true
        onlineTask = Task {
            do {
                let disco = try await catalog.fetchArtistOnlineDiscography(artist: currentArtist, forceRefresh: true)
                guard !Task.isCancelled else {
                    isLoadingOnline = false
                    return
                }
                await MainActor.run {
                    self.discography = disco
                    self.isLoadingOnline = false
                }
            } catch is CancellationError {
                isLoadingOnline = false
            } catch {
                await MainActor.run {
                    self.onlineError = error.localizedDescription
                    self.isLoadingOnline = false
                }
            }
        }
    }

    private func importTrack(_ entry: YTDlpBridge.YTDlpPlaylistEntry) {
        do {
            try catalog.importOnlineTrack(entry: entry, artistName: currentArtist.name)
        } catch {
            onlineError = error.localizedDescription
        }
    }

    private func playOnlineTrack(_ entry: YTDlpBridge.YTDlpPlaylistEntry) {
        Task {
            do {
                let snapshot = try catalog.importOnlineTrack(
                    entry: entry, artistName: currentArtist.name, saveToLibrary: false)
                let context = TrackSnapshot.playbackContext(
                    playing: snapshot, youTubeEntries: discography?.topTracks ?? [])
                playback.playTrack(snapshot, context: context, from: .artist)
            } catch {
                onlineError = error.localizedDescription
            }
        }
    }

    private func importOnlineAlbum(_ release: OnlineReleaseItem) {
        Task {
            let tempRelease = CatalogReleaseProjection(
                stableID: release.stableID,
                title: release.title,
                artistName: currentArtist.name,
                artistStableID: currentArtist.stableID,
                artworkURL: release.artworkURL,
                year: release.year,
                kind: release.kind,
                cacheState: .fresh,
                tracks: []
            )
            do {
                let entries = try await catalog.fetchAlbumOnlineTracks(release: tempRelease)
                try catalog.importOnlineAlbum(release: release, tracks: entries, artistName: currentArtist.name)
            } catch {
                onlineError = error.localizedDescription
            }
        }
    }
}

// MARK: - Supporting Views

struct CatalogLoadingGrid: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 24)], spacing: 24) {
            ForEach(0..<8, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(BrandColors.surface)
                        .aspectRatio(1, contentMode: .fit)
                    RoundedRectangle(cornerRadius: 4).fill(BrandColors.surface)
                        .frame(height: 12)
                    RoundedRectangle(cornerRadius: 4).fill(BrandColors.surface.opacity(0.7))
                        .frame(width: 110, height: 10)
                }
                .redacted(reason: .placeholder)
            }
        }
        .accessibilityLabel(tr("Loading catalog", "正在载入目录"))
    }
}

struct CatalogEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(BrandColors.textSecondary)
            Text(title).font(.headline).foregroundStyle(BrandColors.textPrimary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(BrandColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button(action: onRefresh) {
                Label(tr("Refresh", "刷新"), systemImage: "arrow.clockwise")
            }
            .labelStyle(ActionIconLabelStyle())
            .help(tr("Refresh", "刷新"))
            .musesAction(prominent: true)
            .tint(BrandColors.accent)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

struct CatalogStateBadge: View {
    let state: CatalogCacheState

    var body: some View {
        switch state {
        case .fresh:
            EmptyView()
        case .stale:
            Image(systemName: "clock.badge.exclamationmark")
                .font(.caption.weight(.semibold))
                .padding(6)
                .background(BrandColors.surface, in: Circle())
                .overlay(Circle().stroke(BrandColors.textPrimary.opacity(0.28), lineWidth: 1))
                .help(tr("Cached metadata is stale", "缓存元数据已过期"))
        case .unavailable:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(BrandColors.accent)
                .padding(6)
                .background(BrandColors.surface, in: Circle())
                .overlay(Circle().stroke(BrandColors.textPrimary.opacity(0.28), lineWidth: 1))
                .help(tr("Currently unavailable", "当前不可用"))
        }
    }
}
