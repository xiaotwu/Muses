import SwiftUI

/// A read-only, source-verified Shorts tab for a subscribed channel.
struct YouTubeChannelShortsView: View {
    let channel: YouTubeSubscription
    @Environment(\.ytDlpBridge) private var bridge
    @Environment(YouTubeAccountService.self) private var account
    @Environment(YouTubeSearchService.self) private var search
    @Environment(PlaybackService.self) private var playback
    @State private var state: LoadState<[YTDlpBridge.YTDlpPlaylistEntry]> = .idle
    @State private var nextOffset: Int?
    @State private var loadingMore = false
    @State private var refreshID = UUID()
    @State private var playRequest: YTDlpBridge.YTDlpPlaylistEntry?
    @State private var playbackError: String?
    private let pageSize = 20

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(channel.title).font(.largeTitle.bold())
                    Spacer()
                    ChromeIconButton(systemName: "arrow.clockwise", help: tr("Refresh", "刷新"),
                                     accessibility: tr("Refresh Shorts", "刷新 Shorts", zhHant: "重新整理 Shorts")) {
                        loadingMore = false
                        refreshID = UUID()
                    }.disabled(state.isLoading)
                }
                Text("Shorts").foregroundStyle(.secondary)
                if let message = state.errorMessage {
                    MetadataProjectionErrorBanner(message: message)
                    Button(tr("Retry", "重试", zhHant: "重試")) { refreshID = UUID() }
                }
                if let playbackError { MetadataProjectionErrorBanner(message: playbackError) }
                if state.isLoading { ProgressView() }
                if case .empty = state {
                    ContentUnavailableView(tr("No public Shorts available", "没有可用的公开 Shorts",
                                              zhHant: "沒有可用的公開 Shorts"), systemImage: "play.rectangle")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .top)], spacing: 22) {
                    ForEach(state.value ?? [], id: \.id) { entry in
                        AlbumObjectView(title: entry.title, subtitle: entry.uploader ?? channel.title,
                                        artwork: .resolve(remoteURL: nil, youTubeId: entry.id),
                                        size: 180, role: .play, artworkHeight: 260,
                                        isYouTube: true, showsHoverPlay: true,
                                        onSelect: { playRequest = entry }, onPlay: { playRequest = entry })
                            .youTubeEntryContextMenu(entry: entry) {
                                playRequest = entry
                            }
                    }
                }
                if nextOffset != nil {
                    Button(tr("Load More", "加载更多", zhHant: "載入更多")) {
                        loadingMore = true
                        refreshID = UUID()
                    }.disabled(state.isLoading)
                }
            }
            .padding(28)
            .padding(.bottom, 100)
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
                playback.playTrack(snapshot, context: TrackSnapshot.playbackContext(
                    playing: snapshot, youTubeEntries: entries), from: .search)
            } catch {
                if !Task.isCancelled { playbackError = error.localizedDescription }
            }
            playRequest = nil
        }
    }

    private func load() async {
        guard let bridge, account.isConnected else { return }
        let identity = account.activeChannelID
        let previous = state.value
        let append = loadingMore && nextOffset != nil
        let offset = append ? nextOffset ?? 0 : 0
        state = .loading(previous: previous)
        do {
            let page = try await bridge.fetchShortsPage(channelID: channel.channelId,
                                                       offset: offset, count: pageSize)
            guard !Task.isCancelled, identity == account.activeChannelID else { return }
            var seen = Set<String>()
            let all = ((append ? previous ?? [] : []) + page).filter { seen.insert($0.id).inserted }
            nextOffset = page.count == pageSize && offset + pageSize < 500
                ? offset + pageSize : nil
            loadingMore = false
            state = all.isEmpty ? .empty : .content(all)
        } catch {
            guard !Task.isCancelled, identity == account.activeChannelID else { return }
            state = .failure(message: tr("Shorts could not load. Please retry.",
                                         "无法加载 Shorts，请重试。",
                                         zhHant: "無法載入 Shorts，請重試。"),
                             staleValue: previous)
        }
    }
}
