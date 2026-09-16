import SwiftUI

/// Read-only account browsing reuses the app-lifetime OAuth service. Each channel
/// has a bounded, cancellable page load; switching accounts clears its content.
struct YouTubeSubscriptionsView: View {
    @Environment(YouTubeAccountService.self) private var account
    @Binding var selectedChannelID: String?
    private var selected: YouTubeSubscription? {
        (account.subscriptionsState.value ?? []).first { $0.channelId == selectedChannelID }
    }
    @State private var refreshID = UUID()

    var body: some View {
        Group {
            if let selected, account.isConnected {
                YouTubeChannelUploadsView(channel: selected)
                    .id(selected.channelId)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Text(tr("Subscriptions", "订阅")).font(.largeTitle.bold())
                            Spacer()
                            ChromeIconButton(systemName: "arrow.clockwise", help: tr("Refresh", "刷新"),
                                             accessibility: tr("Refresh subscriptions", "刷新订阅")) {
                                refreshID = UUID()
                            }.disabled(!account.isConnected || account.isConnecting)
                        }
                        if !account.isConnected {
                            ContentUnavailableView {
                                Label(tr("Connect YouTube", "连接 YouTube"), systemImage: "person.crop.circle")
                            } description: {
                                Text(tr("Browse your subscribed channels after connecting your account.", "连接账号后，即可浏览订阅的频道。"))
                            } actions: {
                                Button(tr("Account Settings", "账号设置")) {
                                    NotificationCenter.default.post(name: .musesOpenSettings, object: SettingsCategory.youtube)
                                }
                            }.frame(maxWidth: .infinity)
                        } else {
                            if account.subscriptionsState.isLoading { ProgressView() }
                            if let message = account.subscriptionsState.errorMessage {
                                MetadataProjectionErrorBanner(message: message)
                            }
                            if case .empty = account.subscriptionsState {
                                ContentUnavailableView(tr("No subscriptions", "暂无订阅"), systemImage: "person.crop.rectangle.stack")
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .top)], spacing: 24) {
                                ForEach(account.subscriptionsState.value ?? [], id: \.channelId) { channel in
                                    AlbumObjectView(title: channel.title, subtitle: tr("Channel", "频道"),
                                                    artwork: .resolve(remoteURL: channel.thumbnailURL), size: 180,
                                                    isYouTube: true, onSelect: { selectedChannelID = channel.channelId }, onPlay: { selectedChannelID = channel.channelId })
                                    .contextMenu {
                                        Button(tr("Open", "打开")) { selectedChannelID = channel.channelId }
                                        if let target = YouTubeShareTarget(kind: .channel, id: channel.channelId) {
                                            YouTubeShareMenu(target: target)
                                        }
                                    }
                                }
                            }
                        }
                    }.padding(28).padding(.bottom, 100)
                }
            }
        }
        .task(id: refreshID) {
            if account.isConnected { await account.refresh() }
        }
        .onChange(of: account.activeChannelID) { _, _ in selectedChannelID = nil }
        .onChange(of: account.isConnected) { _, connected in if !connected { selectedChannelID = nil } }
    }
}

private struct YouTubeChannelUploadsView: View {
    let channel: YouTubeSubscription
    @Environment(YouTubeAccountService.self) private var account
    @Environment(YouTubeSearchService.self) private var search
    @Environment(PlaybackService.self) private var playback
    @State private var state: LoadState<[YTDlpBridge.YTDlpPlaylistEntry]> = .idle
    @State private var playlistID: String?
    @State private var nextPage: String?
    @State private var refreshID = UUID()
    @State private var appendPage = false
    @State private var playRequest: YTDlpBridge.YTDlpPlaylistEntry?
    @State private var playbackError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(channel.title).font(.largeTitle.bold())
                    Spacer()
                    if let target = YouTubeShareTarget(kind: .channel, id: channel.channelId) {
                        YouTubeShareMenu(target: target)
                    }
                    ChromeIconButton(systemName: "arrow.clockwise", help: tr("Refresh", "刷新"), accessibility: tr("Refresh", "刷新")) {
                        appendPage = false
                        refreshID = UUID()
                    }.disabled(state.isLoading)
                }
                Text(tr("Channel uploads", "频道上传内容")).foregroundStyle(.secondary)
                if let message = state.errorMessage { MetadataProjectionErrorBanner(message: message) }
                if let playbackError { MetadataProjectionErrorBanner(message: playbackError) }
                if state.isLoading { ProgressView() }
                if case .empty = state {
                    ContentUnavailableView(tr("No public uploads available", "没有可用的公开上传内容"), systemImage: "play.rectangle")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), alignment: .top)], spacing: 24) {
                    ForEach(state.value ?? [], id: \.id) { entry in
                        AlbumObjectView(title: entry.title, subtitle: entry.uploader ?? channel.title,
                                        artwork: .resolve(remoteURL: nil, youTubeId: entry.id), size: 220,
                                        role: .play, artworkHeight: 124, isYouTube: true, showsHoverPlay: true,
                                        onSelect: { playRequest = entry }, onPlay: { playRequest = entry })
                            .youTubeEntryContextMenu(entry: entry) { playRequest = entry }
                    }
                }
                if nextPage != nil {
                    Button(tr("Load More", "加载更多")) {
                        appendPage = true
                        refreshID = UUID()
                    }.disabled(state.isLoading)
                }
            }.padding(28).padding(.bottom, 100)
        }
        .task(id: refreshID) { await load() }
        .task(id: playRequest?.id) {
            guard let entry = playRequest else { return }
            let identity = account.activeChannelID
            let entries = state.value ?? []
            do {
                let snapshot = try await search.resolveTrack(entry: entry)
                guard !Task.isCancelled, identity == account.activeChannelID else { return }
                playbackError = nil
                playback.playTrack(snapshot, context: TrackSnapshot.playbackContext(playing: snapshot, youTubeEntries: entries), from: .search)
            } catch {
                if !Task.isCancelled { playbackError = error.localizedDescription }
            }
            playRequest = nil
        }
    }

    private func load() async {
        guard let client = account.dataAPIClient() else { return }
        let identity = account.activeChannelID
        let previous = state.value
        state = .loading(previous: previous)
        do {
            let id: String?
            if appendPage, let playlistID { id = playlistID }
            else { id = try await client.uploadsPlaylist(channelID: channel.channelId) }
            guard !Task.isCancelled, identity == account.activeChannelID else { return }
            guard let id else { state = .empty; nextPage = nil; return }
            let page = try await client.playlistItemsPage(playlistId: id, pageToken: appendPage ? nextPage : nil)
            guard !Task.isCancelled, identity == account.activeChannelID else { return }
            var seen = Set<String>()
            let entries = page.items.filter { $0.availability == .available }.map {
                YTDlpBridge.YTDlpPlaylistEntry(id: $0.videoId, title: $0.title, uploader: channel.title,
                                             duration: nil, channelID: channel.channelId)
            }
            let all = ((appendPage ? previous ?? [] : []) + entries).filter { seen.insert($0.id).inserted }
            playlistID = id
            nextPage = page.nextPageToken
            state = all.isEmpty ? .empty : .content(all)
        } catch {
            guard !Task.isCancelled, identity == account.activeChannelID else { return }
            state = .failure(message: error.localizedDescription, staleValue: previous)
        }
    }
}
