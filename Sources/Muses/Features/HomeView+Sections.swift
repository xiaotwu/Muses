import AppKit
import SwiftUI

extension HomeView {
    @ViewBuilder
    var topPicks: some View {
        if !topPickItems.isEmpty {
            VStack(alignment: .leading, spacing: 13) {
                SectionHeader(title: tr("Top Picks", "精选推荐"))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 18) {
                        ForEach(topPickItems) { item in
                            portraitCard(item)
                                .frame(width: SongGridMetrics.maxCard)
                        }
                    }
                    .padding(.horizontal, AppleMusicTokens.contentPaddingX)
                }
            }
        } else if discovery.isRefreshing || fallbackLoading || discovery.sections.contains(where: isLoading) {
            portraitSkeletons
        } else {
            HomeDiscoveryEmptyState(onSearch: {
                NotificationCenter.default.post(name: .musesFocusSearch, object: nil)
            }, onRetry: {
                if discovery.isEnabled { discovery.reload() } else { loadFallback() }
            })
            .padding(.horizontal, AppleMusicTokens.contentPaddingX)
        }
    }

    var portraitSkeletons: some View {
        VStack(alignment: .leading, spacing: 13) {
            SectionHeader(title: tr("Top Picks", "精选推荐"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(0..<5, id: \.self) { _ in
                        SkeletonBlock(
                            width: SongGridMetrics.maxCard,
                            height: SongGridMetrics.maxCard + HomeMediaCardMetrics.footerHeight
                        )
                    }
                }
                .padding(.horizontal, AppleMusicTokens.contentPaddingX)
            }
        }
    }

    @ViewBuilder
    func portraitCard(_ item: DiscoveryItem) -> some View {
        switch item {
        case .youTube(let card):
            SongStationCard(
                title: card.title,
                subtitle: card.uploader ?? "YouTube Music",
                artwork: ArtworkSource.resolve(
                    remoteURL: card.thumbnailURL, youTubeId: card.playableVideoID),
                isYouTube: true,
                style: .home,
                onOpen: { Task { await play(card) } },
                onPlay: { Task { await play(card) } }
            )
            .youTubeEntryContextMenu(card: card) {
                Task { await play(card) }
            }
        case .track(let snapshot):
            SongStationCard(
                title: snapshot.title,
                subtitle: snapshot.artist,
                artwork: ArtworkSource.resolve(for: snapshot),
                isYouTube: true,
                nowPlayingID: snapshot.id,
                style: .home,
                onOpen: { play(snapshot, context: supportedRecent) },
                onPlay: { play(snapshot, context: supportedRecent) }
            )
            .trackContextMenu(snapshot: snapshot, onPlay: {
                play(snapshot, context: supportedRecent)
            })
        }
    }

    @ViewBuilder
    var discoveryShelves: some View {
        if discovery.isEnabled {
            let sections = discovery.sections
            let hasLoadedAny = sections.contains { section in
                if case .loaded = section.status { return true }
                return false
            }
            let failedSections = sections.filter { section in
                if case .failed = section.status { return true }
                return false
            }

            if !failedSections.isEmpty && !hasLoadedAny {
                DiscoveryFailureStrip(
                    message: tr("Could not load recommendations right now.", "暂时无法加载推荐内容。"),
                    onRetry: discovery.reload
                )
                .padding(.horizontal, AppleMusicTokens.contentPaddingX)
            } else if !failedSections.isEmpty && hasLoadedAny {
                DiscoveryFailureStrip(
                    message: tr("Some recommendations could not be loaded.", "部分推荐未能加载。"),
                    onRetry: discovery.reload
                )
                .padding(.horizontal, AppleMusicTokens.contentPaddingX)
            }

            ForEach(sections) { section in
                discoveryShelf(section, suppressFailureStrip: !failedSections.isEmpty)
            }
        } else if let fallbackError, fallbackEntries.isEmpty {
            DiscoveryFailureStrip(message: fallbackError, onRetry: loadFallback)
                .padding(.horizontal, AppleMusicTokens.contentPaddingX)
        } else if !fallbackEntries.isEmpty {
            fallbackShelf
        }
    }

    @ViewBuilder
    func discoveryShelf(_ section: HomeSection, suppressFailureStrip: Bool = false) -> some View {
        let items = section.items.filter(isPresentableDiscoveryItem)
        switch section.status {
        case .loading:
            squareShelfSkeleton(title: section.title)
        case .failed(let message):
            if !suppressFailureStrip {
                DiscoveryFailureStrip(
                    message: message ?? tr("This section could not be loaded.", "无法加载此区段。"),
                    onRetry: discovery.reload
                )
                .padding(.horizontal, AppleMusicTokens.contentPaddingX)
            }
        case .idle, .loaded:
            if !items.isEmpty {
                if section.kind == .quickPicks {
                    quickPicksShelf(section, items: items)
                } else {
                    VStack(alignment: .leading, spacing: 13) {
                        discoverySectionHeader(section)
                        ResponsiveCarousel(
                            cardSize: MusicObjectMetrics.albumRail,
                            spacing: 18,
                            alignment: .top
                        ) {
                            ForEach(items) { item in squareCard(item, sectionItems: items) }
                        }
                    }
                }
            }
        }
    }

    func quickPicksShelf(_ section: HomeSection,
                                 items: [DiscoveryItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: section.title,
                              subtitle: sourceAwareSubtitle(section))
                Spacer()
                continuationButton(for: section)
                Button(tr("Play all", "全部播放")) {
                    playAll(items.filter(isPlayableDiscoveryItem))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.trailing, AppleMusicTokens.contentPaddingX)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 28), GridItem(.flexible())],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(items.prefix(8)) { item in
                    quickPickRow(item, context: items)
                }
            }
            .padding(.horizontal, AppleMusicTokens.contentPaddingX)
        }
    }

    @ViewBuilder
    func quickPickRow(_ item: DiscoveryItem,
                              context: [DiscoveryItem]) -> some View {
        switch item {
        case .youTube(let card):
            Button { Task { await play(card, siblings: context) } } label: {
                HStack(spacing: 10) {
                    ArtworkView(
                        source: ArtworkSource.resolve(
                            remoteURL: card.thumbnailURL,
                            youTubeId: card.playableVideoID),
                        cornerRadius: 5, glyphSize: 18, targetSize: 48
                    )
                    .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(card.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(BrandColors.textPrimary)
                            .lineLimit(1)
                        Text(card.uploader ?? "YouTube Music")
                            .font(.caption)
                            .foregroundStyle(BrandColors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(BrandColors.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .youTubeEntryContextMenu(card: card) {
                Task { await play(card, siblings: context) }
            }
        case .track(let snapshot):
            Button { play(snapshot, context: [snapshot]) } label: {
                HStack(spacing: 10) {
                    ArtworkView(source: ArtworkSource.resolve(for: snapshot),
                                cornerRadius: 5, glyphSize: 18, targetSize: 48)
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(snapshot.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(snapshot.artist).font(.caption)
                            .foregroundStyle(BrandColors.textSecondary).lineLimit(1)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
    }

    func squareShelfSkeleton(title: String) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            SectionHeader(title: title)
            ResponsiveCarousel(
                cardSize: MusicObjectMetrics.albumRail,
                spacing: 18,
                alignment: .top
            ) {
                ForEach(0..<5, id: \.self) { _ in
                    SkeletonCard(size: MusicObjectMetrics.albumRail, aspect: .square)
                }
            }
        }
    }

    @ViewBuilder
    func squareCard(_ item: DiscoveryItem, sectionItems: [DiscoveryItem]) -> some View {
        switch item {
        case .youTube(let card):
            let canPlay = card.playableVideoID != nil
            AlbumObjectView(
                title: card.title,
                subtitle: webCardSubtitle(card),
                artwork: ArtworkSource.resolve(
                    remoteURL: card.thumbnailURL, youTubeId: card.playableVideoID),
                size: MusicObjectMetrics.albumRail,
                role: canPlay ? .play : .browse,
                style: .home,
                showsHoverPlay: canPlay,
                onSelect: { openWebCard(card) },
                onPlay: {
                    if canPlay {
                        Task { await play(card, siblings: sectionItems) }
                    } else {
                        openWebCard(card)
                    }
                }
            )
            .youTubeEntryContextMenu(card: card) {
                Task { await play(card, siblings: sectionItems) }
            }
        case .track(let snapshot):
            let context = sectionItems.compactMap { item -> TrackSnapshot? in
                if case .track(let value) = item { return value }
                return nil
            }
            AlbumObjectView(
                title: snapshot.title,
                subtitle: snapshot.artist,
                artwork: ArtworkSource.resolve(for: snapshot),
                size: MusicObjectMetrics.albumRail,
                role: .play,
                style: .home,
                nowPlayingID: snapshot.id,
                showsHoverPlay: true,
                onSelect: {},
                onPlay: { play(snapshot, context: context) }
            )
            .trackContextMenu(snapshot: snapshot, onPlay: { play(snapshot, context: context) })
        }
    }

    var fallbackShelf: some View {
        VStack(alignment: .leading, spacing: 13) {
            SectionHeader(title: tr("Explore on YouTube Music", "探索 YouTube Music"))
            ResponsiveCarousel(
                cardSize: MusicObjectMetrics.albumRail,
                spacing: 18,
                alignment: .top
            ) {
                ForEach(fallbackEntries, id: \.id) { entry in
                    AlbumObjectView(
                        title: entry.title,
                        subtitle: entry.uploader ?? "YouTube Music",
                        artwork: ArtworkSource.resolve(
                            remoteURL: nil, youTubeId: entry.id),
                        size: MusicObjectMetrics.albumRail,
                        role: .play,
                        style: .home,
                        showsHoverPlay: true,
                        onSelect: {},
                        onPlay: { Task { await play(entry) } }
                    )
                    .youTubeEntryContextMenu(entry: entry) {
                        Task { await play(entry) }
                    }
                }
            }
        }
    }

    var importedPlaylistsShelf: some View {
        VStack(alignment: .leading, spacing: 13) {
            SectionHeader(title: tr("Imported Playlists", "已导入歌单"))
            ResponsiveCarousel(
                cardSize: MusicObjectMetrics.albumRail,
                spacing: 18,
                alignment: .top
            ) {
                ForEach(activeImports.prefix(12), id: \.id) { imported in
                    AlbumObjectView(
                        title: imported.title,
                        subtitle: imported.channel,
                        artwork: importArtwork(imported),
                        size: MusicObjectMetrics.albumRail,
                        role: .browse,
                        style: .home,
                        showsHoverPlay: true,
                        onSelect: {
                            NotificationCenter.default.post(
                                name: .musesNavigateYouTubeImport, object: imported)
                        },
                        onPlay: { play(imported) }
                    )
                    .contextMenu {
                        Button(tr("Play", "播放"), systemImage: "play.fill") {
                            play(imported)
                        }
                        Button(tr("Open", "打开")) {
                            NotificationCenter.default.post(
                                name: .musesNavigateYouTubeImport, object: imported)
                        }
                        Button {
                            if let url = URL(string: imported.url) { NSWorkspace.shared.open(url) }
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
                }
            }
        }
    }

    var moodChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(YouTubeHomeMood.all) { mood in
                    MoodChipButton(title: mood.localizedTitle) {
                        globalSearch.scope = .youtube
                        globalSearch.query = mood.searchQuery
                        NotificationCenter.default.post(name: .musesFocusSearch, object: nil)
                    }
                }
            }
            .padding(.horizontal, AppleMusicTokens.contentPaddingX)
            .padding(.vertical, 2)
        }
        .accessibilityLabel(tr("Moods and activities", "心情与活动"))
    }

    var homeSourceStatus: some View {
        HStack(spacing: 7) {
            Image(systemName: homeSourceStatusIcon)
                .font(.caption.weight(.semibold))
            Text(homeSourceStatusText)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            if discovery.isShowingStale {
                Text(tr("Saved", "已保存"))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(BrandColors.textPrimary.opacity(0.08),
                                in: Capsule())
            }
        }
        .foregroundStyle(BrandColors.textSecondary)
        .padding(.horizontal, AppleMusicTokens.contentPaddingX)
        .accessibilityElement(children: .combine)
    }

    var homeSourceStatusText: String {
        let accountName = youTubeAccount.account?.channel?.title
        switch discovery.webCapability {
        case .available:
            return tr("YouTube Music personalized · " + (accountName ?? "Account"),
                      "YouTube Music 个性化 · " + (accountName ?? "账号"))
        case .saved:
            return tr("Saved YouTube Music personalized · " + (accountName ?? "Account"),
                      "已保存的 YouTube Music 个性化 · " + (accountName ?? "账号"))
        case .unavailable, .rejected:
            return tr("Official YouTube account + public discovery",
                      "YouTube 官方账号内容 + 公共发现")
        case .notConfigured, .signedOut:
            if youTubeAccount.activeChannelID != nil {
                return tr("Official YouTube account + public discovery",
                          "YouTube 官方账号内容 + 公共发现")
            }
            return tr("Public discovery", "公共发现")
        }
    }

    var homeSourceStatusIcon: String {
        switch discovery.webCapability {
        case .available: "person.crop.circle.fill.badge.checkmark"
        case .saved: "clock.arrow.circlepath"
        case .unavailable, .rejected: "arrow.down.right.circle"
        case .notConfigured, .signedOut:
            youTubeAccount.activeChannelID == nil ? "globe" : "person.crop.circle"
        }
    }

    var staleBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
            VStack(alignment: .leading, spacing: 2) {
                Text(isShowingSavedWeb
                     ? tr("Showing saved YouTube Music personalization.",
                          "正在显示已保存的 YouTube Music 个性化内容。")
                     : tr("Showing saved Home recommendations.",
                          "正在显示已保存的首页推荐。"))
                    .font(.caption.weight(.semibold))
                Text(staleBannerDetail)
                    .font(.caption2)
                    .lineLimit(2)
            }
            Spacer()
            Button(tr("Retry", "重试")) { discovery.reload() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .foregroundStyle(BrandColors.textSecondary)
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(BrandColors.surface,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, AppleMusicTokens.contentPaddingX)
    }

    var isShowingSavedWeb: Bool {
        discovery.sections.contains {
            $0.source == .cached && $0.cachedOrigin == .signedInWeb
        }
    }

    var staleBannerDetail: String {
        let updated = discovery.lastUpdatedAt.map {
            tr("Updated \($0.formatted(date: .abbreviated, time: .shortened))",
               "更新于 \($0.formatted(date: .abbreviated, time: .shortened))")
        }
        return [updated, discovery.lastRefreshError]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var shouldShowWebRecovery: Bool {
        guard webHome.isEnabled,
              !isShowingSavedWeb,
              discovery.lastRefreshError != nil else { return false }
        return switch discovery.webCapability {
        case .unavailable, .rejected: true
        default: false
        }
    }

    var webRecoveryBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Personalized Web Home is unavailable",
                        "个性化 Web 首页暂不可用"))
                    .font(.subheadline.weight(.semibold))
                Text(discovery.lastRefreshError
                     ?? tr("Official account and public discovery remain available.",
                           "YouTube 官方账号内容与公共发现仍可使用。"))
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
            Button(tr("Retry", "重试")) { discovery.reload() }
                .buttonStyle(.bordered)
            Button(tr("Settings", "设置")) {
                NotificationCenter.default.post(
                    name: .musesOpenSettings, object: SettingsCategory.youtube)
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(BrandColors.surface,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, AppleMusicTokens.contentPaddingX)
        .accessibilityElement(children: .contain)
    }

    var guestBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 18, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Make Home yours", "让首页更懂你"))
                    .font(.subheadline.weight(.semibold))
                Text(tr("Guest discovery and playback already work. Sign in to add your YouTube likes, subscriptions, and owned playlists.",
                        "访客发现与播放已经可用。登录后可加入你的 YouTube 点赞、订阅和自有歌单。"))
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
            Button(tr("Sign In", "登录")) {
                NotificationCenter.default.post(
                    name: .musesOpenSettings, object: SettingsCategory.youtube)
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandColors.magenta)
        }
        .padding(14)
        .background(BrandColors.surface,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, AppleMusicTokens.contentPaddingX)
    }

    var accountRefreshFailureBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.system(size: 18, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Some YouTube account data is unavailable",
                        "部分 YouTube 账号数据暂不可用"))
                    .font(.subheadline.weight(.semibold))
                Text(tr(
                    "Saved recommendations remain visible. Retry without signing out.",
                    "已保存的推荐仍会显示；可直接重试，无需退出登录。"))
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
            }
            Spacer()
            Button(tr("Retry", "重试")) {
                Task { await youTubeAccount.refresh() }
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(BrandColors.surface,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, AppleMusicTokens.contentPaddingX)
    }

    var focusState: some View {
        EmptyStateView(
            icon: "brain.head.profile",
            title: tr("Focusing", "专注中"),
            subtitle: tr(
                "Discovery is hidden while Focus Mode is active. Your playlists stay available.",
                "专注模式开启时会隐藏发现内容；歌单仍可使用。"
            )
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    func refreshRecentlyPlayed() {
        recentlyPlayed = library.recentlyPlayedTracks(limit: 20)
            .filter { !$0.youTubeId.isEmpty }
    }

    func loadFallback() {
        fallbackTask?.cancel()
        fallbackLoading = true
        fallbackError = nil
        fallbackTask = Task {
            do {
                let entries = try await youTubeSearch.search(query: "official music", limit: 18)
                guard !Task.isCancelled else { return }
                fallbackEntries = entries.filter(YouTubeMusicTrust.isTrustedHomeEntry)
            } catch {
                guard !Task.isCancelled else { return }
                fallbackError = tr("YouTube Music discovery is unavailable.",
                                   "YouTube Music 发现内容暂不可用。")
            }
            fallbackLoading = false
        }
    }

    func play(_ snapshot: TrackSnapshot,
                      context: [TrackSnapshot],
                      source: QueueSource = .search) {
        let playableContext = context.isEmpty ? [snapshot] : context
        playback.playTrack(snapshot, context: playableContext, from: source)
    }

    func play(_ card: YouTubeDiscoveryCard,
                      siblings: [DiscoveryItem]? = nil) async {
        guard let videoID = card.playableVideoID else {
            interactionError = tr(
                "This YouTube Music item is not available for playback.",
                "此 YouTube Music 内容当前不可播放。")
            return
        }
        let entry = YTDlpBridge.YTDlpPlaylistEntry(
            id: videoID,
            title: card.title,
            uploader: card.uploader,
            duration: card.duration
        )
        do {
            let snapshot = try await youTubeSearch.importAsTrack(entry: entry)
            let entries = (siblings ?? itemsContaining(card)).compactMap { item -> YTDlpBridge.YTDlpPlaylistEntry? in
                guard case .youTube(let sibling) = item,
                      let siblingVideoID = sibling.playableVideoID else { return nil }
                return YTDlpBridge.YTDlpPlaylistEntry(
                    id: siblingVideoID,
                    title: sibling.title,
                    uploader: sibling.uploader,
                    duration: sibling.duration
                )
            }
            let context = TrackSnapshot.playbackContext(playing: snapshot, youTubeEntries: entries)
            interactionError = nil
            playback.playTrack(snapshot, context: context, from: .search)
        } catch {
            interactionError = tr(
                "This YouTube Music item could not be prepared: \(error.localizedDescription)",
                "无法准备此 YouTube Music 内容：\(error.localizedDescription)"
            )
        }
    }

    func play(_ entry: YTDlpBridge.YTDlpPlaylistEntry) async {
        do {
            let snapshot = try await youTubeSearch.importAsTrack(entry: entry)
            let context = TrackSnapshot.playbackContext(
                playing: snapshot,
                youTubeEntries: fallbackEntries
            )
            interactionError = nil
            playback.playTrack(snapshot, context: context, from: .search)
        } catch {
            interactionError = tr(
                "This YouTube Music item could not be prepared: \(error.localizedDescription)",
                "无法准备此 YouTube Music 内容：\(error.localizedDescription)"
            )
        }
    }

    func play(_ imported: YouTubeImport) {
        let snapshots = (imported.items ?? [])
            .sorted { $0.order < $1.order }
            .compactMap(\.track)
            .filter { !$0.youTubeId.isEmpty }
            .map(TrackSnapshot.init(from:))
        guard let first = snapshots.first else {
            interactionError = tr(
                "This playlist has no playable YouTube items.",
                "这个歌单中没有可播放的 YouTube 内容。"
            )
            return
        }
        interactionError = nil
        playback.playTrack(first, context: snapshots, from: .import)
    }

    func playAll(_ items: [DiscoveryItem]) {
        Task {
            var snapshots: [TrackSnapshot] = []
            var failedTitles: [String] = []
            for item in items {
                switch item {
                case .track(let snapshot):
                    snapshots.append(snapshot)
                case .youTube(let card):
                    guard let videoID = card.playableVideoID else {
                        failedTitles.append(card.title)
                        continue
                    }
                    let entry = YTDlpBridge.YTDlpPlaylistEntry(
                        id: videoID, title: card.title,
                        uploader: card.uploader, duration: card.duration)
                    do {
                        let snapshot = try await youTubeSearch.importAsTrack(entry: entry)
                        snapshots.append(snapshot)
                    } catch {
                        failedTitles.append(card.title)
                    }
                }
            }
            guard let first = snapshots.first else {
                interactionError = tr(
                    "None of these songs could be prepared for playback.",
                    "这些歌曲目前都无法准备播放。"
                )
                return
            }
            interactionError = failedTitles.isEmpty ? nil : tr(
                "Playing available songs. Could not prepare: \(failedTitles.joined(separator: ", "))",
                "正在播放可用歌曲。以下内容无法准备：\(failedTitles.joined(separator: "、"))"
            )
            playback.playTrack(first, context: snapshots, from: .search)
        }
    }

    func importArtwork(_ imported: YouTubeImport) -> ArtworkSource {
        let firstID = (imported.items ?? []).min(by: { $0.order < $1.order })?.youTubeId
        return ArtworkSource.resolve(
            remoteURL: imported.artworkUrl,
            youTubeId: firstID
        )
    }

    func itemsContaining(_ card: YouTubeDiscoveryCard) -> [DiscoveryItem] {
        discovery.sections.first { section in
            section.items.contains { item in
                guard case .youTube(let candidate) = item else { return false }
                return candidate.id == card.id
            }
        }?.items ?? []
    }

    func isPlayableDiscoveryItem(_ item: DiscoveryItem) -> Bool {
        switch item {
        case .youTube(let card): return card.playableVideoID?.isEmpty == false
        case .track(let snapshot): return !snapshot.youTubeId.isEmpty
        }
    }

    func isPresentableDiscoveryItem(_ item: DiscoveryItem) -> Bool {
        switch item {
        case .youTube(let card): return !card.id.isEmpty
        case .track(let snapshot): return !snapshot.youTubeId.isEmpty
        }
    }

    @ViewBuilder
    func discoverySectionHeader(_ section: HomeSection) -> some View {
        HStack(alignment: .firstTextBaseline) {
            SectionHeader(
                title: section.title,
                subtitle: sourceAwareSubtitle(section))
            Spacer()
            continuationButton(for: section)
        }
        .padding(.trailing, AppleMusicTokens.contentPaddingX)
    }

    @ViewBuilder
    func continuationButton(for section: HomeSection) -> some View {
        if section.source == .signedInWeb,
           webHome.hasContinuation(for: section.id) {
            Button {
                Task {
                    do {
                        let items = try await webHome.fetchContinuation(for: section.id)
                        discovery.appendWebContinuation(items, to: section.id)
                    } catch let error as WebHomeContinuationError {
                        interactionError = continuationFailureMessage(error.code)
                    } catch {
                        interactionError = tr(
                            "More recommendations are temporarily unavailable.",
                            "暂时无法加载更多推荐。")
                    }
                }
            } label: {
                Label(tr("More", "更多"), systemImage: "chevron.right.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(webHome.status == .refreshing || webHome.status == .checking)
            .help(tr("Load more from this personalized section",
                     "从此个性化区段加载更多内容"))
            .accessibilityLabel(tr("Load more (section.title)",
                                   "加载更多(section.title)"))
        }
    }

    func openWebCard(_ card: YouTubeDiscoveryCard) {
        guard let endpoint = card.browseEndpoint ?? card.playEndpoint else { return }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "music.youtube.com"
        switch endpoint.kind {
        case .video:
            components.path = "/watch"
            components.queryItems = [URLQueryItem(name: "v", value: endpoint.identifier)]
        case .playlist:
            components.path = "/playlist"
            components.queryItems = [URLQueryItem(name: "list", value: endpoint.identifier)]
        case .browse:
            components.path = "/browse/\(endpoint.identifier)"
        case .channel:
            components.path = "/channel/\(endpoint.identifier)"
        }
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    func webCardSubtitle(_ card: YouTubeDiscoveryCard) -> String {
        let base = card.uploader ?? "YouTube Music"
        let state: String? = switch card.availability {
        case .available: nil
        case .unavailable: tr("Unavailable", "不可用")
        case .regionBlocked: tr("Not available in this region", "此地区不可用")
        case .privateItem: tr("Private", "私密")
        case .deleted: tr("Deleted", "已删除")
        }
        return state.map { "\(base) · \($0)" } ?? base
    }

    func continuationFailureMessage(_ code: HomeFetchFailureCode) -> String {
        switch code {
        case .sessionExpired:
            tr("Your Web session expired. Check it again in YouTube Settings.",
               "Web 会话已过期，请在 YouTube 设置中重新检查。")
        case .accountMismatch:
            tr("The Web session belongs to another channel.",
               "Web 会话属于另一个频道。")
        case .shapeChanged:
            tr("YouTube Music changed this section's response.",
               "YouTube Music 已更改此区段的响应结构。")
        default:
            tr("More recommendations are temporarily unavailable.",
               "暂时无法加载更多推荐。")
        }
    }

    func isLoading(_ section: HomeSection) -> Bool {
        if case .loading = section.status { return true }
        return false
    }

    func sourceAwareSubtitle(_ section: HomeSection) -> String {
        let source: String
        if section.source == .cached {
            let origin = section.cachedOrigin?.label ?? HomeSource.publicDiscovery.label
            source = tr("Saved · \(origin)", "已保存 · \(origin)")
        } else {
            source = section.source.label
        }
        guard let subtitle = section.subtitle, !subtitle.isEmpty,
              !subtitle.localizedCaseInsensitiveContains(source) else { return source }
        return "\(subtitle) · \(source)"
    }
}

private struct MoodChipButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(BrandColors.textPrimary)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background {
                    if reduceTransparency {
                        BrandColors.surface
                    } else {
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Capsule()
                                    .fill(isHovered ? BrandColors.textPrimary.opacity(0.10) : BrandColors.textPrimary.opacity(0.04))
                            )
                    }
                }
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(isHovered ? BrandColors.textPrimary.opacity(0.28) : BrandColors.hairline, lineWidth: 1)
                }
                .scaleEffect(isHovered && !reduceMotion ? 1.03 : 1.0)
                .offset(y: isHovered && !reduceMotion ? -1 : 0)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(MusesMotion.hoverAnimation(reduceMotion: reduceMotion), value: isHovered)
    }
}

