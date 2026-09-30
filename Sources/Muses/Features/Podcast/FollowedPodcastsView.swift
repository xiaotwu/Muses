import SwiftUI

/// Local follows are separate from the connected account's channel subscriptions.
struct FollowedPodcastsView: View {
    @Environment(PodcastLibraryService.self) private var podcasts
    @Environment(YouTubeSearchService.self) private var search
    @Environment(YouTubeAccountService.self) private var account
    @Environment(PlaybackService.self) private var playback
    @State private var browser = MusicCatalogBrowser()
    @State private var shows: [PodcastShowSnapshot] = []
    @State private var selectedID: String?
    @State private var episodeStates: [String: PodcastEpisodeSnapshot] = [:]
    @State private var unplayedQueue = PodcastUnplayedQueue(videoIDs: [], order: .sourceOrder)
    @State private var operationFailed = false
    @State private var metadataTask: Task<Void, Never>?
    @State private var metadataFetchedIDs: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(tr("Followed Podcasts", "已关注的播客", zhHant: "已追蹤的 Podcast"))
                        .font(MusesTypography.pageTitle)
                        .foregroundStyle(BrandColors.heading)
                    Spacer()
                    if selectedID != nil {
                        ChromeIconButton(systemName: "arrow.clockwise",
                            help: tr("Refresh Podcast", "刷新播客", zhHant: "重新整理 Podcast"),
                            accessibility: tr("Refresh Podcast", "刷新播客", zhHant: "重新整理 Podcast")) {
                            browser.refresh()
                            metadataFetchedIDs = []
                        }
                    }
                }

                if shows.isEmpty {
                    ContentUnavailableView(
                        tr("No followed podcasts", "尚未关注播客", zhHant: "尚未追蹤 Podcast"),
                        systemImage: "mic",
                        description: Text(tr("Find a podcast in Search and follow it here.",
                                             "在搜索中找到播客并关注后，会显示在这里。",
                                             zhHant: "在搜尋中找到 Podcast 並追蹤後，會顯示在這裡。")))
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(shows) { show in
                                Button {
                                    selectedID = show.catalogID
                                    metadataTask?.cancel()
                                    metadataFetchedIDs = []
                                    browser.browse(catalogItem(show))
                                    refreshEpisodeStates()
                                } label: {
                                    Text(show.title).lineLimit(1)
                                        .padding(.horizontal, 14).padding(.vertical, 8)
                                }
                                .buttonStyle(.bordered)
                                .accessibilityAddTraits(selectedID == show.catalogID ? .isSelected : [])
                            }
                        }
                    }
                }

                if let selectedID, let show = shows.first(where: { $0.catalogID == selectedID }) {
                    HStack {
                        Text(show.title).font(.title2.weight(.semibold))
                        Spacer()
                        if browser.loading { ProgressView().controlSize(.small) }
                    }
                    if browser.failed {
                        HStack {
                            Text(browser.isStale
                                ? tr("Refresh failed. Showing saved episodes.",
                                     "刷新失败，正在显示已保存的单集。",
                                     zhHant: "重新整理失敗，正在顯示已儲存的單集。")
                                : tr("Podcast could not load.", "无法加载播客。", zhHant: "無法載入 Podcast。"))
                            Button(tr("Retry", "重试", zhHant: "重試")) { browser.retry() }
                        }.font(.callout)
                    }
                    if operationFailed || podcasts.persistenceFailed {
                        Text(tr("Podcast change could not be saved. Please retry.",
                                "播客更改未能保存，请重试。",
                                zhHant: "Podcast 更改未能儲存，請重試。"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if browser.nextCursor == nil && !browser.loading && !unplayedQueue.videoIDs.isEmpty {
                        HStack(spacing: 10) {
                            Button(tr("Play Unplayed", "播放未听单集", zhHant: "播放未聽單集")) {
                                playUnplayed()
                            }
                            Text(unplayedQueue.order == .publicationDate
                                 ? tr("Oldest first by publication date", "按发布日期从旧到新", zhHant: "依發布日期由舊到新")
                                 : tr("Source order; publication dates unavailable",
                                      "来源顺序；缺少发布日期",
                                      zhHant: "來源順序；缺少發布日期"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Array(browser.items.enumerated()), id: \.offset) { index, item in
                        if item.kind == .episode, let entry = episodeEntry(item, showTitle: show.title) {
                            if episodeStates[entry.id]?.availability == .unavailable {
                                episodeRow(item, index: index)
                            } else {
                                episodeRow(item, index: index)
                                    .youTubeEntryContextMenu(entry: entry,
                                                             mediaKind: .podcastEpisode) {
                                        play(item, at: index)
                                    }
                            }
                        }
                    }
                    if browser.nextCursor != nil {
                        Button(tr("Load more", "加载更多", zhHant: "載入更多")) { browser.more() }
                            .disabled(browser.loading)
                    }
                    if browser.items.isEmpty && !browser.loading && !browser.failed {
                        Text(tr("No episodes available.", "暂无可用单集。", zhHant: "暫無可用單集。"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, AppleMusicTokens.contentPaddingX)
            .padding(.top, AppleMusicSpacing.browseTitleTop)
            .padding(.bottom, AppleMusicTokens.scrollBottomInset)
        }
        .background(BrowseBackground())
        .onAppear { refreshShows() }
        .onChange(of: podcasts.revision) { _, _ in refreshShows(); refreshEpisodeStates() }
        .onChange(of: browser.fetchedAt) { _, _ in ingestVisibleEpisodes() }
        .onChange(of: account.activeChannelID) { _, _ in
            metadataTask?.cancel()
            metadataFetchedIDs = []
            enrichVisibleEpisodes()
        }
        .onDisappear {
            browser.cancel()
            metadataTask?.cancel()
        }
    }

    private func episodeRow(_ item: MusicCatalogItem, index: Int) -> some View {
        let videoID = String(item.id.dropFirst("video:".count))
        let state = episodeStates[videoID]
        return HStack(spacing: 10) {
            ArtworkView(source: ArtworkSource.resolve(remoteURL: item.artwork?.absoluteString,
                                                       youTubeId: videoID),
                        cornerRadius: 5, glyphSize: 16, targetSize: 42)
                .frame(width: 42, height: 42).accessibilityHidden(true)
            Button { play(item, at: index) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).lineLimit(1)
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let state {
                        Text(state.availability == .unavailable
                            ? tr("Unavailable", "不可用", zhHant: "無法使用")
                            : state.completed
                            ? tr("Played", "已听完", zhHant: "已聽完")
                            : tr("Unplayed", "未听", zhHant: "未聽"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.fullAreaPlain)
                .disabled(state?.availability == .unavailable)
            Button {
                do {
                    if state?.completed == true { try podcasts.markUnplayed(videoID: videoID) }
                    else { try podcasts.markPlayed(videoID: videoID) }
                    operationFailed = false
                } catch { operationFailed = true }
            } label: {
                Image(systemName: state?.completed == true ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.fullAreaPlain)
            .help(state?.completed == true
                ? tr("Mark unplayed", "标为未听", zhHant: "標為未聽")
                : tr("Mark played", "标为已听", zhHant: "標為已聽"))
            .accessibilityLabel((state?.completed == true
                ? tr("Mark unplayed", "标为未听", zhHant: "標為未聽")
                : tr("Mark played", "标为已听", zhHant: "標為已聽")) + " " + item.title)
        }.padding(.vertical, 3)
    }

    private func play(_ item: MusicCatalogItem, at index: Int) {
        guard let entry = episodeEntry(item, showTitle: selectedShowTitle) else { return }
        guard episodeStates[entry.id]?.availability != .unavailable else { return }
        let preceding = browser.items.prefix(index).filter { $0.kind == .episode }
        let entries = browser.items.filter { $0.kind == .episode }
            .compactMap { episodeEntry($0, showTitle: selectedShowTitle) }
        Task {
            do {
                let snapshot = try await search.resolveTrack(
                    entry: entry, mediaKindOverride: .podcastEpisode)
                let state = podcasts.episode(videoID: entry.id)
                playback.playTrack(snapshot, context: TrackSnapshot.playbackContext(
                    playing: snapshot, youTubeEntries: entries,
                    selectedIndex: preceding.count, mediaKind: .podcastEpisode),
                    from: .podcast,
                    resumeAtMs: state.flatMap { $0.completed ? nil : $0.lastPositionMs })
                operationFailed = false
            } catch { operationFailed = true }
        }
    }

    private func refreshShows() {
        shows = podcasts.followedShows()
        if let selectedID, !shows.contains(where: { $0.catalogID == selectedID }) {
            self.selectedID = nil
            episodeStates = [:]
            unplayedQueue = .init(videoIDs: [], order: .sourceOrder)
            browser.clear()
        }
    }

    private func ingestVisibleEpisodes() {
        guard let selectedID, let show = shows.first(where: { $0.catalogID == selectedID }) else { return }
        do {
            try podcasts.ingest(show: catalogItem(show),
                                episodes: browser.items.filter { $0.kind == .episode })
            operationFailed = false
            refreshEpisodeStates()
            enrichVisibleEpisodes()
        } catch { operationFailed = true }
    }

    private func enrichVisibleEpisodes() {
        guard let client = account.dataAPIClient(), let selectedID else { return }
        let ids = browser.items.filter { $0.kind == .episode }
            .map { String($0.id.dropFirst("video:".count)) }
        let pending = Array(Set(ids).subtracting(metadataFetchedIDs)).sorted()
        guard !pending.isEmpty else { return }
        metadataTask?.cancel()
        metadataTask = Task {
            for offset in stride(from: 0, to: pending.count, by: 50) {
                let batch = Array(pending[offset..<min(offset + 50, pending.count)])
                do {
                    let values = try await client.videoMetadata(ids: batch)
                    guard !Task.isCancelled, self.selectedID == selectedID else { return }
                    try podcasts.enrich(values)
                    metadataFetchedIDs.formUnion(batch)
                    operationFailed = false
                } catch {
                    guard !Task.isCancelled, self.selectedID == selectedID else { return }
                    operationFailed = true
                    return
                }
            }
        }
    }

    private func refreshEpisodeStates() {
        guard let selectedID else {
            episodeStates = [:]
            unplayedQueue = .init(videoIDs: [], order: .sourceOrder)
            return
        }
        episodeStates = Dictionary(uniqueKeysWithValues:
            podcasts.episodes(showCatalogID: selectedID).map { ($0.videoID, $0) })
        unplayedQueue = podcasts.unplayedQueue(showCatalogID: selectedID,
            sourceVideoIDs: browser.items.filter { $0.kind == .episode }
                .map { String($0.id.dropFirst("video:".count)) })
    }

    private func playUnplayed() {
        let byID = Dictionary(browser.items.filter { $0.kind == .episode }.compactMap { item in
            episodeEntry(item, showTitle: selectedShowTitle).map { ($0.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        let entries = unplayedQueue.videoIDs.compactMap { byID[$0] }
        guard let first = entries.first else { return }
        Task {
            do {
                let snapshot = try await search.resolveTrack(
                    entry: first, mediaKindOverride: .podcastEpisode)
                playback.playTrack(snapshot, context: TrackSnapshot.playbackContext(
                    playing: snapshot, youTubeEntries: entries,
                    selectedIndex: 0, mediaKind: .podcastEpisode),
                    from: .podcast,
                    resumeAtMs: episodeStates[first.id]?.lastPositionMs)
                operationFailed = false
            } catch { operationFailed = true }
        }
    }

    private func catalogItem(_ show: PodcastShowSnapshot) -> MusicCatalogItem {
        .init(id: show.catalogID, kind: .podcast, title: show.title, subtitle: "",
              artwork: show.artworkURL.flatMap(URL.init(string:)),
              artists: [], releases: [], channels: [])
    }

    private var selectedShowTitle: String {
        shows.first(where: { $0.catalogID == selectedID })?.title ?? ""
    }

    private func episodeEntry(_ item: MusicCatalogItem, showTitle: String)
        -> YTDlpBridge.YTDlpPlaylistEntry? {
        guard let entry = item.playableEntry else { return nil }
        return .init(id: entry.id, title: entry.title,
                     uploader: entry.uploader ?? (showTitle.isEmpty ? nil : showTitle),
                     duration: entry.duration, playlistTitle: showTitle,
                     channelID: entry.channelID, track: entry.track,
                     album: entry.album, releaseYear: entry.releaseYear)
    }
}
