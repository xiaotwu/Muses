import SwiftUI

/// Account browsing and confirmed subscription changes reuse the app-lifetime
/// OAuth service. Switching accounts clears the selected channel content.
struct YouTubeSubscriptionsView: View {
    @Environment(YouTubeAccountService.self) private var account
    @Binding var selectedChannelID: String?
    private var selected: YouTubeSubscription? {
        (account.subscriptionsState.value ?? []).first { $0.channelId == selectedChannelID }
    }
    @State private var refreshID = UUID()
    @State private var channelInput = ""
    @State private var pendingChannel: YouTubeChannel?
    @State private var pendingAccountID: String?
    @State private var showingSubscribe = false
    @State private var resolvingChannel = false
    @State private var subscriptionError: String?

    var body: some View {
        Group {
            if let selected, account.isConnected {
                YouTubeChannelContentView(channel: selected)
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
                            HStack {
                                TextField(tr("YouTube channel URL or ID", "YouTube 频道链接或 ID", zhHant: "YouTube 頻道連結或 ID"),
                                          text: $channelInput)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel(tr("YouTube channel URL or ID", "YouTube 频道链接或 ID", zhHant: "YouTube 頻道連結或 ID"))
                                Button(tr("Find Channel", "查找频道", zhHant: "尋找頻道")) {
                                    Task { await resolveChannel() }
                                }
                                .disabled(channelInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || resolvingChannel)
                            }
                            if resolvingChannel { ProgressView() }
                            if let subscriptionError { MetadataProjectionErrorBanner(message: subscriptionError) }
                            if !account.canManagePlaylists {
                                Button(tr("Allow Subscription Changes…", "允许修改订阅…", zhHant: "允許修改訂閱…")) {
                                    Task { await account.requestPlaylistManagementAccess() }
                                }
                            }
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
        .alert(
            tr("Subscribe to \(pendingChannel?.title ?? "") (\(pendingChannel?.id ?? "")) using \(account.account?.channel?.title ?? "YouTube")?",
               "使用 \(account.account?.channel?.title ?? "YouTube") 账号订阅 \(pendingChannel?.title ?? "")（\(pendingChannel?.id ?? "")）？",
               zhHant: "使用 \(account.account?.channel?.title ?? "YouTube") 帳號訂閱 \(pendingChannel?.title ?? "")（\(pendingChannel?.id ?? "")）？"),
            isPresented: $showingSubscribe
        ) {
            Button(tr("Subscribe", "订阅", zhHant: "訂閱")) {
                guard let channel = pendingChannel, let ownerID = pendingAccountID else { return }
                pendingChannel = nil
                pendingAccountID = nil
                Task {
                    do {
                        guard account.activeChannelID == ownerID else {
                            throw YouTubeAccountWriteError.accountChanged
                        }
                        try await account.subscribe(channelID: channel.id)
                        subscriptionError = nil
                        channelInput = ""
                    } catch { subscriptionError = error.localizedDescription }
                }
            }
        }
    }

    private func resolveChannel() async {
        guard let client = account.dataAPIClient(), let ownerID = account.activeChannelID else { return }
        let input = channelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let id: String
        if input.hasPrefix("UC"), input.count == 24 { id = input }
        else if let url = URL(string: input), let target = YouTubeShareTarget(url: url),
                target.kind == .channel { id = target.id }
        else {
            subscriptionError = tr("Enter a stable /channel/ URL or channel ID.",
                                   "请输入稳定的 /channel/ 链接或频道 ID。",
                                   zhHant: "請輸入穩定的 /channel/ 連結或頻道 ID。")
            return
        }
        resolvingChannel = true
        subscriptionError = nil
        defer { resolvingChannel = false }
        do {
            guard let channel = try await client.channel(id: id),
                  account.activeChannelID == ownerID else {
                throw YouTubeAccountWriteError.invalidTarget
            }
            if (account.subscriptionsState.value ?? []).contains(where: { $0.channelId == id }) {
                subscriptionError = tr("Already subscribed to this channel.",
                                       "已订阅此频道。", zhHant: "已訂閱此頻道。")
            } else {
                pendingAccountID = ownerID
                pendingChannel = channel
                showingSubscribe = true
            }
        } catch { subscriptionError = error.localizedDescription }
    }
}

private struct YouTubeChannelContentView: View {
    let channel: YouTubeSubscription
    @State private var tab: ChannelTab = .uploads

    private enum ChannelTab: String, CaseIterable {
        case uploads, shorts
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(tr("Channel content", "频道内容", zhHant: "頻道內容"), selection: $tab) {
                Text(tr("Uploads", "上传内容", zhHant: "上傳內容")).tag(ChannelTab.uploads)
                Text("Shorts").tag(ChannelTab.shorts)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            .padding(.top, 12)
            if tab == .uploads {
                YouTubeChannelUploadsView(channel: channel)
            } else {
                YouTubeChannelShortsView(channel: channel)
            }
        }
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
    @State private var accountActionError: String?
    @State private var showingUnsubscribe = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(channel.title).font(.largeTitle.bold())
                    Spacer()
                    if !channel.id.isEmpty {
                        Button(tr("Unsubscribe", "取消订阅")) {
                            showingUnsubscribe = true
                        }
                        .buttonStyle(.bordered)
                        .help(tr("Unsubscribe from this channel", "取消订阅此频道"))
                    }
                    if let target = YouTubeShareTarget(kind: .channel, id: channel.channelId) {
                        YouTubeShareMenu(target: target, chrome: true)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    ChromeIconButton(systemName: "arrow.clockwise", help: tr("Refresh", "刷新"), accessibility: tr("Refresh", "刷新")) {
                        appendPage = false
                        refreshID = UUID()
                    }.disabled(state.isLoading)
                }
                Text(tr("Channel uploads", "频道上传内容")).foregroundStyle(.secondary)
                if let message = state.errorMessage { MetadataProjectionErrorBanner(message: message) }
                if let playbackError { MetadataProjectionErrorBanner(message: playbackError) }
                if let accountActionError { MetadataProjectionErrorBanner(message: accountActionError) }
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
        .alert(
            tr("Unsubscribe from \(channel.title) (\(channel.channelId)) using \(account.account?.channel?.title ?? "YouTube")?",
               "使用 \(account.account?.channel?.title ?? "YouTube") 账号取消订阅 \(channel.title)（\(channel.channelId)）？",
               zhHant: "使用 \(account.account?.channel?.title ?? "YouTube") 帳號取消訂閱 \(channel.title)（\(channel.channelId)）？"),
            isPresented: $showingUnsubscribe
        ) {
            Button(tr("Cancel", "取消"), role: .cancel) {}
            Button(tr("Unsubscribe", "取消订阅"), role: .destructive) {
                let ownerID = account.activeChannelID
                Task {
                    do {
                        guard ownerID == account.activeChannelID else {
                            throw YouTubeAccountWriteError.accountChanged
                        }
                        try await account.unsubscribe(subscriptionID: channel.id)
                        accountActionError = nil
                    } catch { accountActionError = error.localizedDescription }
                }
            }
        }
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
