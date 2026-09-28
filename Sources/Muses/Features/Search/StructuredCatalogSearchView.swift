import AppKit
import SwiftUI

struct StructuredCatalogSearchView: View {
    @Environment(GlobalSearchService.self) private var search
    @Environment(PlaybackService.self) private var playback
    @Environment(PodcastLibraryService.self) private var podcasts
    @Environment(YouTubeAccountService.self) private var account
    @State private var playbackError = false
    @State private var podcastError = false
    @State private var followingPodcast = false
    @State private var episodeStates: [String: PodcastEpisodeSnapshot] = [:]
    @State private var pendingSubscription: MusicCatalogChannel?
    @State private var showingSubscribe = false
    @State private var pendingSubscriptionOwnerID: String?
    @State private var accountActionError: String?
    private var browser: MusicCatalogBrowser { search.musicCatalog }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(browser.detail?.title ?? "YouTube Music").font(.title3.weight(.semibold))
                Spacer()
                if let detail = browser.detail, detail.kind == .podcast {
                    Button(followingPodcast
                           ? tr("Unfollow", "取消关注", zhHant: "取消追蹤")
                           : tr("Follow", "关注", zhHant: "追蹤")) {
                        togglePodcastFollow(detail)
                    }
                    .accessibilityLabel(followingPodcast
                        ? tr("Unfollow podcast", "取消关注播客", zhHant: "取消追蹤 Podcast")
                        : tr("Follow podcast", "关注播客", zhHant: "追蹤 Podcast"))
                    if let channel = subscribableChannel(for: detail),
                       account.isConnected,
                       !(account.account?.subscriptions.contains(where: {
                           $0.channelId == String(channel.id.dropFirst("browse:".count))
                       }) ?? false) {
                        Button(tr("Subscribe on YouTube", "在 YouTube 订阅", zhHant: "在 YouTube 訂閱")) {
                            pendingSubscription = channel
                            pendingSubscriptionOwnerID = account.activeChannelID
                            showingSubscribe = true
                        }
                    }
                }
                if browser.loading { ProgressView().controlSize(.small) }
            }
            if browser.detail?.kind == .album, let metadata = browser.metadata {
                if !metadata.subtitle.isEmpty {
                    Text(metadata.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                if !metadata.artists.isEmpty {
                    Text(tr("Album artists", "专辑艺人", zhHant: "專輯藝人")).font(.caption).foregroundStyle(.secondary)
                    ForEach(metadata.artists, id: \.id) { artist in
                        Button(artist.title) {
                            browser.open(.init(id: artist.id, kind: .artist, title: artist.title,
                                               subtitle: "", artwork: nil, artists: [], releases: [], channels: []))
                        }
                        .buttonStyle(.fullAreaPlain)
                        .accessibilityLabel(tr("Album artist", "专辑艺人", zhHant: "專輯藝人") + " " + artist.title)
                    }
                }
            }
            if browser.detail == nil {
                Picker(tr("Category", "类别", zhHant: "類別"), selection: Binding(get: { browser.kind }, set: { browser.search(search.query, kind: $0) })) {
                    Text(tr("All", "全部")).tag(MusicCatalogKind?.none)
                    ForEach(MusicCatalogKind.searchableCases, id: \.self) { kind in
                        Text(kind.title).tag(Optional(kind))
                    }
                }.pickerStyle(.menu).fixedSize()
            }
            if browser.failed {
                HStack {
                    Text(browser.isStale
                         ? tr("Refresh failed. Showing saved results.", "刷新失败，正在显示缓存结果。", zhHant: "重新整理失敗，正在顯示快取結果。")
                         : tr("YouTube Music could not load these results.", "无法加载这些 YouTube Music 结果。", zhHant: "無法載入這些 YouTube Music 結果。"))
                    Button(tr("Retry", "重试", zhHant: "重試")) { browser.retry() }.disabled(browser.loading)
                }.font(.callout)
            }
            if playbackError {
                Text(tr("Playback could not start. Please try again.", "无法开始播放，请重试。", zhHant: "無法開始播放，請再試一次。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if podcastError || podcasts.persistenceFailed {
                Text(tr("Podcast changes could not be saved. Please retry.",
                        "播客更改未能保存，请重试。", zhHant: "Podcast 更改未能儲存，請重試。"))
                    .foregroundStyle(.secondary)
            }
            if let accountActionError {
                Text(accountActionError).font(.callout).foregroundStyle(.secondary)
            }
            if browser.detail == nil && browser.kind == nil {
                ForEach(MusicCatalogKind.searchableCases, id: \.self) { kind in
                    let items = browser.items.filter { $0.kind == kind }
                    if !items.isEmpty {
                        HStack {
                            Text(kind.title).font(.headline)
                            Spacer()
                            Button(tr("See all", "查看全部", zhHant: "查看全部")) { browser.search(search.query, kind: kind) }
                                .accessibilityLabel(tr("See all", "查看全部", zhHant: "查看全部") + " " + kind.title)
                        }
                        ForEach(items.prefix(5)) { item in row(item) }
                    }
                }
            } else {
                // Offset preserves repeated source playlist occurrences.
                ForEach(Array(browser.items.enumerated()), id: \.offset) { index, item in row(item, index: index) }
            }
            if !browser.relatedItems.isEmpty {
                Text(tr("Related on YouTube Music", "YouTube Music 关联内容", zhHant: "YouTube Music 關聯內容")).font(.headline)
                ForEach(browser.relatedItems) { item in row(item, related: true) }
            }
            if browser.items.isEmpty && browser.relatedItems.isEmpty && !browser.loading && !browser.failed && browser.fetchedAt != nil {
                Text(tr("No results available.", "暂无可用结果。", zhHant: "暫無可用結果。"))
                    .foregroundStyle(.secondary)
            }
            if browser.nextCursor != nil {
                Button(tr("Load more", "加载更多", zhHant: "載入更多")) { browser.more() }.disabled(browser.loading)
            }
            if let fetched = browser.fetchedAt {
                HStack(spacing: 5) {
                    Text("YouTube Music · \(browser.language) · \(browser.region)")
                    Text(fetched, style: .date)
                    Text(fetched, style: .time)
                }.font(.caption).foregroundStyle(.secondary)
            }
            Divider().padding(.vertical, 8)
        }
        .task(id: search.query + "|" + search.scope.rawValue) {
            browser.clear()
            guard search.scope.searchesYouTube, !search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard !Task.isCancelled, !search.wasCancelled else { return }
            browser.search(search.query)
        }
        .onDisappear { browser.cancel() }
        .onChange(of: browser.fetchedAt) { _, _ in syncPodcastDetail() }
        .onChange(of: browser.detail?.id) { _, _ in refreshPodcastPresentation() }
        .onChange(of: podcasts.revision) { _, _ in refreshPodcastPresentation() }
        .confirmationDialog(
            tr("Subscribe to \(pendingSubscription?.title ?? "") as \(account.account?.channel?.title ?? "YouTube")?",
               "使用 \(account.account?.channel?.title ?? "YouTube") 账号订阅 \(pendingSubscription?.title ?? "")？",
               zhHant: "使用 \(account.account?.channel?.title ?? "YouTube") 帳號訂閱 \(pendingSubscription?.title ?? "")？"),
            isPresented: $showingSubscribe
        ) {
            Button(tr("Subscribe", "订阅", zhHant: "訂閱")) {
                guard let target = pendingSubscription else { return }
                let ownerID = pendingSubscriptionOwnerID
                pendingSubscription = nil
                Task {
                    do {
                        guard ownerID == account.activeChannelID else {
                            throw YouTubeAccountWriteError.accountChanged
                        }
                        try await account.subscribe(channelID:
                            String(target.id.dropFirst("browse:".count)))
                        accountActionError = nil
                    } catch { accountActionError = error.localizedDescription }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: MusicCatalogItem, index: Int? = nil, related: Bool = false) -> some View {
        if let entry = item.playableEntry,
           podcastState(item)?.availability != .unavailable {
            rowContent(item, index: index, related: related)
                .youTubeEntryContextMenu(entry: entry,
                                         mediaKind: item.kind == .episode ? .podcastEpisode : .song) {
                    activate(item, index: index, related: related)
                }
        } else { rowContent(item, index: index, related: related) }
    }

    private func rowContent(_ item: MusicCatalogItem, index: Int?, related: Bool) -> some View {
        HStack(spacing: 10) {
            ArtworkView(source: ArtworkSource.resolve(remoteURL: (item.artwork ?? browser.detail?.artwork)?.absoluteString,
                                                       youTubeId: item.id.hasPrefix("video:") ? String(item.id.dropFirst(6)) : nil),
                        cornerRadius: 5, glyphSize: 16, targetSize: 42)
                .frame(width: 42, height: 42).accessibilityHidden(true)
            Button { activate(item, index: index, related: related) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).lineLimit(1)
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let state = podcastState(item) {
                        Text(state.availability == .unavailable
                             ? tr("Unavailable", "不可用", zhHant: "無法使用")
                             : state.completed
                             ? tr("Played", "已听完", zhHant: "已聽完")
                             : state.lastPositionMs > 0
                                ? tr("Resume", "继续播放", zhHant: "繼續播放") + " · " + formatPosition(state.lastPositionMs)
                                : tr("Unplayed", "未听", zhHant: "未聽"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.fullAreaPlain)
                .disabled(podcastState(item)?.availability == .unavailable)
            if item.playableEntry != nil && podcastState(item)?.availability != .unavailable {
                Button { activate(item, index: index, related: related) } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.fullAreaPlain).help(tr("Play", "播放"))
                    .accessibilityLabel(tr("Play", "播放") + " " + item.title)
            }
            if let state = podcastState(item) {
                Button {
                    do {
                        if state.completed { try podcasts.markUnplayed(videoID: state.videoID) }
                        else { try podcasts.markPlayed(videoID: state.videoID) }
                        podcastError = false
                    } catch { podcastError = true }
                } label: {
                    Image(systemName: state.completed ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.fullAreaPlain)
                .help(state.completed
                    ? tr("Mark unplayed", "标为未听", zhHant: "標為未聽")
                    : tr("Mark played", "标为已听", zhHant: "標為已聽"))
                .accessibilityLabel((state.completed
                    ? tr("Mark unplayed", "标为未听", zhHant: "標為未聽")
                    : tr("Mark played", "标为已听", zhHant: "標為已聽")) + " " + item.title)
            }
        }.padding(.vertical, 3)
    }

    private func activate(_ item: MusicCatalogItem, index: Int? = nil, related: Bool = false) {
        if item.id.hasPrefix("browse:") { browser.open(item); return }
        guard podcastState(item)?.availability != .unavailable else { return }
        guard let entry = item.playableEntry, let resolver = search.youTubeSearch else {
            if item.id.hasPrefix("video:"), let url = URL(string: "https://music.youtube.com/watch?v=" + item.id.dropFirst(6)) { NSWorkspace.shared.open(url) }
            return
        }
        let sourceItems = related ? browser.relatedItems : browser.items
        let contextItems = sourceItems.filter { ($0.kind == .episode) == (item.kind == .episode) }
        let entries = contextItems.compactMap(\.playableEntry)
        let selectedIndex = index.map { sourceItems.prefix($0).filter {
            ($0.kind == .episode) == (item.kind == .episode)
        }.compactMap(\.playableEntry).count }
        Task {
            do {
                let snapshot = try await resolver.resolveTrack(
                    entry: entry,
                    mediaKindOverride: item.kind == .episode ? .podcastEpisode : nil)
                playbackError = false
                let podcast = item.kind == .episode
                playback.playTrack(
                    snapshot,
                    context: TrackSnapshot.playbackContext(
                        playing: snapshot, youTubeEntries: entries,
                        selectedIndex: selectedIndex,
                        mediaKind: podcast ? .podcastEpisode : .song),
                    from: podcast ? .podcast : .search,
                    resumeAtMs: podcastState(item).flatMap { $0.completed ? nil : $0.lastPositionMs })
            } catch { playbackError = true }
        }
    }

    private func togglePodcastFollow(_ show: MusicCatalogItem) {
        do {
            if podcasts.isFollowing(catalogID: show.id) {
                try podcasts.unfollow(catalogID: show.id)
            } else {
                try podcasts.follow(show)
                syncPodcastDetail()
            }
            podcastError = false
            refreshPodcastPresentation()
        } catch { podcastError = true }
    }

    private func syncPodcastDetail() {
        guard let show = browser.detail, show.kind == .podcast else { return }
        do {
            try podcasts.ingest(show: show, episodes: browser.items.filter { $0.kind == .episode })
            podcastError = false
            refreshPodcastPresentation()
        } catch { podcastError = true }
    }

    private func refreshPodcastPresentation() {
        guard let show = browser.detail, show.kind == .podcast else {
            followingPodcast = false
            episodeStates = [:]
            return
        }
        followingPodcast = podcasts.isFollowing(catalogID: show.id)
        episodeStates = Dictionary(uniqueKeysWithValues:
            podcasts.episodes(showCatalogID: show.id).map { ($0.videoID, $0) })
    }

    private func podcastState(_ item: MusicCatalogItem) -> PodcastEpisodeSnapshot? {
        guard item.kind == .episode, item.id.hasPrefix("video:") else { return nil }
        return episodeStates[String(item.id.dropFirst("video:".count))]
    }

    private func formatPosition(_ milliseconds: Double) -> String {
        let seconds = max(0, Int(milliseconds / 1000))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func subscribableChannel(for show: MusicCatalogItem) -> MusicCatalogChannel? {
        guard show.channels.count == 1, let channel = show.channels.first,
              channel.id.hasPrefix("browse:UC") else { return nil }
        let id = String(channel.id.dropFirst("browse:".count))
        return id.count == 24 && MusicCatalogParser.validID(id) ? channel : nil
    }
}

extension MusicCatalogKind {
    var title: String {
        switch self {
        case .song: tr("Songs", "歌曲")
        case .video: tr("Videos", "视频", zhHant: "影片")
        case .album: tr("Albums", "专辑", zhHant: "專輯")
        case .artist: tr("Artists", "艺人", zhHant: "藝人")
        case .playlist: tr("Playlists", "歌单", zhHant: "播放列表")
        case .podcast: tr("Podcasts", "播客")
        case .episode: tr("Episodes", "单集", zhHant: "單集")
        }
    }
}
