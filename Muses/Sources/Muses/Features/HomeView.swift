import SwiftUI
import AppKit
import SwiftData

/// 首页:Hero 动态封面 + 最近添加 + 钉选 + YouTube 热门搜索 + 已导入歌单 + 全部专辑。
struct HomeView: View {
    @Binding var selection: SidebarSection
    @Binding var selectedAlbum: Album?
    @Environment(LibraryService.self) private var library
    @Environment(PlaybackService.self) private var playback
    @Environment(YouTubeSearchService.self) private var ytSearch
    @Environment(YouTubeImportService.self) private var importService
    @Environment(FocusService.self) private var focus
    @Environment(HomeDiscoveryService.self) private var homeDiscovery
    @Query(sort: \YouTubeImport.importedAt, order: .reverse) private var ytImports: [YouTubeImport]
    @State private var heroGradient: [Color] = [BrandColors.background, BrandColors.surface]
    @State private var ytTrending: [YTDlpBridge.YTDlpPlaylistEntry] = []
    @State private var trendingLoading = false
    @State private var trendingError: String?
    /// 缓存资料库快照,避免在 computed property 中每次渲染都 fetch。
    @State private var albums: [Album] = []
    @State private var recentlyAdded: [Album] = []
    @State private var pinnedAlbumsCache: [Album] = []
    @State private var heroAlbum: Album? = nil
    /// 最近播放的曲目快照(本地 + YouTube),供 "Recently Played" 区。
    @State private var recentlyPlayed: [TrackSnapshot] = []
    /// 在途任务句柄(用于 disappear 取消,spec §23)。
    @State private var trendingTask: Task<Void, Never>?
    @State private var gradientTask: Task<Void, Never>?
    @State private var retryingIDs: Set<String> = []
    @State private var playingAlbumID: UUID?
    @State private var playingArtistID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PrefKey.ytCookieSource) private var cookieSourceRaw = YTCookieSource.none.rawValue

    /// Hero 专辑:优先选最近播放的,否则最近添加的,否则第一个。
    /// 现在读取缓存的 `heroAlbum`,由 `refreshLibrarySnapshot()` 维护。

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Phase D4 — Apple Music 风格大标题(~30pt)。保留既有信息架构与行为。
                Text(tr("Home", "首页"))
                    .font(.system(size: AppleMusicTokens.pageTitleSize, weight: .heavy))
                    .foregroundStyle(BrandColors.textPrimary)
                    .padding(.horizontal, 24)

                if !topPickItems.isEmpty {
                    listenNowTopPicks
                }

                // Recently Played(本地 + YouTube,来源播放历史)
                if !recentlyPlayed.isEmpty {
                    recentlyPlayedSection
                }

                // Top Picks for you(来源 YouTube Music)—— 专注模式开启时抑制发现表面(Final Spec §10.9)。
                // Phase D3:ffDiscovery 开启时,改为渲染来自 HomeDiscoveryService 的动态区段
                // (标题/内容由 provider 产出,cache-first + per-section failure);关闭时保持现有行为。
                if !focus.isActive {
                    if homeDiscovery.isEnabled {
                        discoveryFeedSection
                    } else {
                        topPicksSection
                    }
                }

                if !homeDiscovery.isEnabled, !ytImports.isEmpty {
                    youtubeImportsSection
                }

                if homeDiscovery.isEnabled, !focus.isActive {
                    Color.clear
                        .frame(height: 1)
                        .onAppear { homeDiscovery.loadMore() }
                    if homeDiscovery.isLoadingMore {
                        ProgressView().frame(maxWidth: .infinity).padding(.bottom, 24)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 100)
        }
        .background(BrowseBackground())
        .onAppear {
            PerfTrace.event("home.appear")
            refreshPlayingCollection()
            // 将资料库快照从同步 appear 路径延迟到首帧绘制后(spec §15/§16),
            // 让骨架/缓存内容先上屏。
            Task { @MainActor in
                refreshLibrarySnapshot()
                PerfTrace.event("home.firstCachedContent")
            }
            updateGradientAsync()
            // Discovery and trending spawn yt-dlp. Let the first Home frame
            // paint from cache / library snapshot first.
            Task { @MainActor in
                loadTrending()
                homeDiscovery.load()
            }
        }
        .onDisappear {
            // 页面切换取消非必要任务(spec §23)。
            trendingTask?.cancel(); trendingTask = nil
            gradientTask?.cancel(); gradientTask = nil
            homeDiscovery.cancel()
        }
        .onChange(of: heroAlbum?.id) { _, _ in updateGradientAsync() }
        .onChange(of: library.metadataRevision) { _, _ in refreshLibrarySnapshot() }
        .onChange(of: library.pinRevision) { _, _ in refreshLibrarySnapshot() }
        .onChange(of: library.likedRevision) { _, _ in refreshLibrarySnapshot() }
        .onChange(of: library.playRevision) { _, _ in refreshRecentlyPlayed() }
        .onChange(of: homeDiscovery.isRefreshing) { _, refreshing in
            if !refreshing { retryingIDs.removeAll() }
        }
        .onChange(of: playback.state.track?.id) { _, _ in refreshPlayingCollection() }
    }

    /// 一次性刷新资料库快照(专辑 / 最近添加 / 钉选 / Hero / 最近播放),
    /// 避免每次渲染都 fetch + O(albums×tracks) 排序。
    private func refreshLibrarySnapshot() {
        let allAlbums = library.allAlbums()
        albums = allAlbums
        recentlyAdded = allAlbums.sorted { a, b in
            let aDate = a.tracks.map(\.addedAt).max() ?? .distantPast
            let bDate = b.tracks.map(\.addedAt).max() ?? .distantPast
            return aDate > bDate
        }.prefix(20).map { $0 }
        pinnedAlbumsCache = library.pinnedAlbums()
        heroAlbum = library.mostRecentlyPlayedAlbum() ?? allAlbums.first
        refreshRecentlyPlayed()
    }

    /// 刷新 "Recently Played"(本地 + YouTube 播放历史)。
    private func refreshRecentlyPlayed() {
        recentlyPlayed = library.recentlyPlayedTracks(limit: 20)
    }

    private var mixedDiscoveryItems: [DiscoveryItem] {
        homeDiscovery.sections.first(where: { $0.kind == .mixed || $0.kind == .youTubeCarousel })?.items
            ?? homeDiscovery.sections.first?.items ?? []
    }

    private var mixedSectionID: String? {
        homeDiscovery.sections.first(where: { $0.kind == .mixed || $0.kind == .youTubeCarousel })?.id
            ?? homeDiscovery.sections.first?.id
    }

    private var topPickItems: [DiscoveryItem] {
        let hero: DiscoveryItem? = heroAlbum.map { .album(AlbumRef(album: $0)) }
        let recent = recentlyPlayed.map { DiscoveryItem.track($0) }
        return TopPicksResolver.picks(hero: hero, mixed: mixedDiscoveryItems, recent: recent)
    }

    private var listenNowTopPicks: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(topPickItems) { item in
                        editorialCard(item)
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    @ViewBuilder
    private func editorialCard(_ item: DiscoveryItem) -> some View {
        switch item {
        case .youTube(let card):
            EditorialCard(
                eyebrow: tr("Featured", "精选"),
                title: card.title,
                subtitle: card.uploader ?? "YouTube",
                artwork: ArtworkSource.resolve(
                    hash: nil, remoteURL: card.thumbnailURL, youTubeId: card.id),
                onOpen: { Task { await playYouTubeCard(card) } },
                onPlay: { Task { await playYouTubeCard(card) } }
            )
        case .album(let ref):
            EditorialCard(
                eyebrow: tr("Album", "专辑"),
                title: ref.title,
                subtitle: ref.albumArtist,
                artwork: ArtworkSource.resolve(
                    hash: ref.artworkHash, remoteURL: nil, youTubeId: nil),
                onOpen: {
                    if let album = albums.first(where: { $0.id == ref.id }) {
                        selectedAlbum = album
                    }
                },
                onPlay: {
                    if let album = albums.first(where: { $0.id == ref.id }) {
                        playAlbum(album)
                    }
                }
            )
        case .track(let snap):
            EditorialCard(
                eyebrow: tr("Song", "歌曲"),
                title: snap.title,
                subtitle: snap.artist,
                artwork: ArtworkSource.resolve(for: snap),
                onOpen: { playback.playTrack(snap, context: recentlyPlayed, from: .songs) },
                onPlay: { playback.playTrack(snap, context: recentlyPlayed, from: .songs) }
            )
        case .playlist(let ref):
            EditorialCard(
                eyebrow: tr("Playlist", "歌单"),
                title: ref.name,
                subtitle: ref.isYouTube ? "YouTube" : tr("Playlist", "歌单"),
                artwork: ArtworkSource.resolve(
                    hash: nil, remoteURL: ref.artworkUrl, youTubeId: ref.firstYouTubeVideoId),
                onOpen: {},
                onPlay: {}
            )
        }
    }

    @ViewBuilder
    private func discoveryCard(_ item: DiscoveryItem, size: CGFloat) -> some View {
        switch item {
        case .youTube(let card):
            AlbumObjectView(
                title: card.title,
                subtitle: card.uploader ?? "YouTube",
                artwork: ArtworkSource.resolve(
                    hash: nil, remoteURL: card.thumbnailURL, youTubeId: card.id),
                size: size,
                role: .play,
                showsHoverPlay: true,
                onSelect: {},
                onPlay: { Task { await playYouTubeCard(card) } }
            )
        case .album(let ref):
            AlbumObjectView(
                title: ref.title,
                subtitle: ref.albumArtist,
                artwork: ArtworkSource.resolve(
                    hash: ref.artworkHash, remoteURL: nil, youTubeId: nil),
                size: size,
                role: .browse,
                isNowPlaying: ref.id == playingAlbumID,
                showsHoverPlay: true,
                onSelect: {
                    if let album = albums.first(where: { $0.id == ref.id }) {
                        selectedAlbum = album
                    }
                },
                onPlay: {
                    if let album = albums.first(where: { $0.id == ref.id }) {
                        playAlbum(album)
                    }
                }
            )
        case .track(let snap):
            AlbumObjectView(
                title: snap.title,
                subtitle: snap.artist,
                artwork: ArtworkSource.resolve(for: snap),
                size: size,
                role: .play,
                showsHoverPlay: true,
                onSelect: {},
                onPlay: { playback.playTrack(snap, context: recentlyPlayed, from: .songs) }
            )
        case .playlist:
            EmptyView()
        }
    }

    // MARK: - Hero

    private func heroSection(_ album: Album) -> some View {
        HeroObjectView(
            title: album.title,
            subtitle: album.albumArtist,
            metadata: album.year.map(String.init),
            artwork: ArtworkSource.resolve(
                hash: album.artworkHash,
                remoteURL: album.artworkUrl,
                youTubeId: album.tracks.first?.youTubeId),
            gradient: heroGradient,
            isNowPlaying: album.id == playingAlbumID,
            showsHoverPlay: true,
            onOpen: { selectedAlbum = album },
            onPlay: { playAlbum(album) }
        )
    }

    // MARK: - 横向滚动区(Phase D4:复用 SectionHeader + ResponsiveCarousel + AlbumObjectView)

    private func horizontalSection(title: String, albums: [Album]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
            ResponsiveCarousel(cardSize: MusicObjectMetrics.albumRail) {
                ForEach(albums, id: \.id) { album in
                    AlbumObjectView(
                        title: album.title,
                        subtitle: album.albumArtist,
                        artwork: ArtworkSource.resolve(
                            hash: album.artworkHash,
                            remoteURL: album.artworkUrl,
                            youTubeId: album.tracks.first?.youTubeId),
                        size: MusicObjectMetrics.albumRail,
                        role: .browse,
                        isNowPlaying: album.id == playingAlbumID,
                        showsHoverPlay: true,
                        onSelect: { selectedAlbum = album },
                        onPlay: { playAlbum(album) }
                    )
                }
            }
        }
    }

    // MARK: - Recently Played(本地 + YouTube 播放历史)

    @ViewBuilder
    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: tr("Recently Played", "最近播放"))
            ResponsiveCarousel(cardSize: MusicObjectMetrics.albumRail) {
                ForEach(recentlyPlayed, id: \.id) { snap in
                    AlbumObjectView(
                        title: snap.title,
                        subtitle: snap.artist,
                        artwork: ArtworkSource.resolve(for: snap),
                        size: MusicObjectMetrics.albumRail,
                        role: .play,
                        nowPlayingID: snap.id,
                        showsHoverPlay: true,
                        onSelect: {},
                        onPlay: { playback.playTrack(snap, context: recentlyPlayed, from: .recently) }
                    )
                    .trackContextMenu(snapshot: snap, onPlay: {
                        playback.playTrack(snap, context: recentlyPlayed, from: .recently)
                    })
                }
            }
        }
    }

    // MARK: - Top Picks for you(来源 YouTube Music)

    @ViewBuilder
    private var topPicksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: tr("Top Picks for you", "为你推荐"),
                          subtitle: tr("YouTube Music", "YouTube 音乐"))

            if trendingLoading {
                // Phase D4:骨架替代居中 spinner(§15)。
                ResponsiveCarousel(cardSize: 160) {
                    ForEach(0..<5, id: \.self) { _ in SkeletonCard(size: 160, aspect: .wide169) }
                }
            } else if let err = trendingError {
                VStack(spacing: 8) {
                    Text(err).font(.caption).foregroundStyle(BrandColors.textSecondary)
                    Button(tr("Retry", "重试")) { loadTrending() }
                        .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else if !ytTrending.isEmpty {
                ResponsiveCarousel(cardSize: MusicObjectMetrics.albumRail) {
                    ForEach(ytTrending.prefix(10), id: \.id) { entry in
                        AlbumObjectView(
                            title: entry.title,
                            subtitle: entry.uploader ?? "YouTube",
                            artwork: ArtworkSource.resolve(hash: nil, remoteURL: nil, youTubeId: entry.id),
                            size: MusicObjectMetrics.albumRail,
                            role: .play,
                            showsHoverPlay: true,
                            onSelect: {},
                            onPlay: { Task { await playYouTube(entry) } }
                        )
                        .trackContextMenu(
                            snapshot: TrackSnapshot(
                                id: UUID(), title: entry.title,
                                artist: entry.uploader ?? "YouTube",
                                albumTitle: nil, durationSeconds: entry.duration ?? 0,
                                filePath: nil, youTubeId: entry.id,
                                artworkHash: nil, artworkUrl: YouTubeThumbnail.urlString(videoId: entry.id),
                                sampleRate: 0, bitDepth: 0, codec: "YouTube", isLossless: false),
                            onPlay: { Task { await playYouTube(entry) } }
                        )
                    }
                }
            }
        }
    }

    // MARK: - 已导入的 YouTube 歌单

    @ViewBuilder
    private var youtubeImportsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: tr("Imported Playlists", "已导入歌单"))
            ResponsiveCarousel(cardSize: MusicObjectMetrics.albumRail) {
                ForEach(ytImports.prefix(10), id: \.id) { imp in
                    AlbumObjectView(
                        title: imp.title,
                        subtitle: imp.channel,
                        artwork: importArtwork(imp),
                        size: MusicObjectMetrics.albumRail,
                        role: .browse,
                        showsHoverPlay: true,
                        onSelect: {
                            NotificationCenter.default.post(name: .musesNavigateYouTubeImport, object: imp)
                        },
                        onPlay: { playImport(imp) }
                    )
                    .contextMenu {
                        Button(tr("Play", "播放")) { playImport(imp) }
                        Button(tr("Open", "打开")) {
                            NotificationCenter.default.post(name: .musesNavigateYouTubeImport, object: imp)
                        }
                        Button(tr("Open on YouTube", "在 YouTube 打开")) {
                            if let url = URL(string: imp.url) { NSWorkspace.shared.open(url) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Phase D3:动态发现流

    /// 渲染 `HomeDiscoveryService.sections`:每 section 独立状态(cache-first + per-section failure)。
    /// 标题/副标题来自 provider,视图不硬编码 YouTube Music 区段名。
    @ViewBuilder
    private var discoveryFeedSection: some View {
        let failed = homeDiscovery.sections.filter {
            if case .failed = $0.status { return true }
            return false
        }
        let live = homeDiscovery.sections.filter {
            if case .failed = $0.status { return false }
            return true
        }
        VStack(alignment: .leading, spacing: 32) {
            ForEach(live) { section in
                if section.id != mixedSectionID {
                    discoverySection(section)
                }
            }
            if !failed.isEmpty, !(homeDiscovery.isRefreshing && !retryingIDs.isEmpty) {
                discoveryFailureBanner(failed)
            } else if !failed.isEmpty {
                ResponsiveCarousel(cardSize: 160) {
                    ForEach(0..<5, id: \.self) { _ in SkeletonCard(size: 160, aspect: .wide169) }
                }
            }
        }
    }

    private func discoveryFailureBanner(_ sections: [HomeSection]) -> some View {
        let message = sections.compactMap { section -> String? in
            if case .failed(let msg) = section.status { return msg }
            return nil
        }.first
        return VStack(alignment: .leading, spacing: 10) {
            Text(tr("YouTube discovery unavailable", "无法加载 YouTube 发现"))
                .font(.headline)
                .foregroundStyle(BrandColors.textPrimary)
            Text(message ?? tr("Couldn’t load this section", "无法加载该区段"))
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
            Text(YouTubeIdentity.discoveryCookieHint(
                cookieSource: YTCookieSource(rawValue: cookieSourceRaw) ?? .none))
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
            HStack(spacing: 12) {
                Button(tr("Retry", "重试")) {
                    for section in sections { retryingIDs.insert(section.id) }
                    homeDiscovery.reload()
                }
                .buttonStyle(.bordered)
                Button(tr("YouTube Settings", "YouTube 设置")) {
                    NotificationCenter.default.post(
                        name: .musesOpenSettings, object: SettingsCategory.youtube)
                }
                .buttonStyle(.bordered)
            }
            .tint(BrandColors.magenta)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrandColors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func discoverySection(_ section: HomeSection) -> some View {
        // 已加载但无结果:整段(含 SectionHeader)静默折叠。
        if (section.status == .loaded || section.status == .idle) && section.items.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: section.title, subtitle: section.subtitle)

                switch section.status {
                case .loading:
                    // 无缓存冷启:骨架占位(不使用居中 spinner,§15)。
                    ResponsiveCarousel(cardSize: MusicObjectMetrics.albumRail) {
                        ForEach(0..<5, id: \.self) { _ in SkeletonCard(size: 160, aspect: .square) }
                    }
                case .failed:
                    EmptyView()
                case .loaded, .idle:
                    ResponsiveCarousel(cardSize: MusicObjectMetrics.albumRail) {
                        ForEach(section.items) { item in
                            if case .youTube(let card) = item {
                                AlbumObjectView(
                                    title: card.title,
                                    subtitle: card.uploader ?? "YouTube",
                                    artwork: ArtworkSource.resolve(
                                        hash: nil, remoteURL: card.thumbnailURL, youTubeId: card.id),
                                    size: MusicObjectMetrics.albumRail,
                                    role: .play,
                                    showsHoverPlay: true,
                                    onSelect: {},
                                    onPlay: { Task { await playYouTubeCard(card) } }
                                )
                                .trackContextMenu(
                                    snapshot: TrackSnapshot(
                                        id: UUID(), title: card.title,
                                        artist: card.uploader ?? "YouTube",
                                        albumTitle: nil, durationSeconds: card.duration ?? 0,
                                        filePath: nil, youTubeId: card.id,
                                        artworkHash: nil, artworkUrl: card.thumbnailURL,
                                        sampleRate: 0, bitDepth: 0, codec: "YouTube", isLossless: false),
                                    onPlay: { Task { await playYouTubeCard(card) } }
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func playYouTubeCard(_ card: YouTubeDiscoveryCard) async {
        // 复用 ytSearch.importAsTrack 路径:把卡片转成 entry 形态再导入播放。
        let entry = YTDlpBridge.YTDlpPlaylistEntry(
            id: card.id, title: card.title,
            uploader: card.uploader, duration: card.duration)
        do {
            let snap = try await ytSearch.importAsTrack(entry: entry)
            let siblings = sectionItems(for: card)
            let context = TrackSnapshot.playbackContext(playing: snap, youTubeEntries: siblings)
            playback.playTrack(snap, context: context, from: .search)
        } catch {
            // 静默:发现流播放失败不弹错(与现有 playYouTube 行为一致)。
        }
    }

    // MARK: - 全部专辑

    private var allAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: tr("All Albums", "全部专辑"))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 5),
                      spacing: 20) {
                ForEach(albums, id: \.id) { album in
                    AlbumObjectView(
                        title: album.title,
                        subtitle: album.albumArtist,
                        artwork: ArtworkSource.resolve(
                            hash: album.artworkHash,
                            remoteURL: album.artworkUrl,
                            youTubeId: album.tracks.first?.youTubeId),
                        size: MusicObjectMetrics.albumGrid,
                        role: .browse,
                        isNowPlaying: album.id == playingAlbumID,
                        showsHoverPlay: true,
                        onSelect: { selectedAlbum = album },
                        onPlay: { playAlbum(album) }
                    )
                    .contextMenu {
                        Button(library.isPinned(album) ? tr("Unpin", "取消钉选") : tr("Pin", "钉选")) {
                            library.togglePin(album)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - 辅助

    /// 异步提取 Hero 渐变:磁盘读取移出主线程,颜色提取在主线程快速完成。
    private func updateGradientAsync() {
        gradientTask?.cancel()
        guard let album = heroAlbum,
              let hash = album.artworkHash,
              let path = ArtworkCache.default.path(forHash: hash) else { return }
        gradientTask = Task { @MainActor in
            // 磁盘 I/O + 解码放到 detached,避免阻塞首帧。
            let data = await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: path)
            }.value
            guard !Task.isCancelled, let data, let img = NSImage(data: data) else { return }
            let colors = AlbumArtworkExtractor.dominantColors(img, count: 4)
            guard !Task.isCancelled else { return }
            heroGradient = colors.map { Color(nsColor: $0) } + [BrandColors.background]
            PerfTrace.event("home.gradientReady")
        }
    }

    private func refreshPlayingCollection() {
        let id = playback.state.track?.id
        playingAlbumID = id.flatMap { library.track(by: $0)?.album?.id }
        playingArtistID = id.flatMap { library.track(by: $0)?.artistRef?.id }
    }

    private func playAlbum(_ album: Album) {
        let tracks = library.tracks(in: album)
        let snaps = tracks.map { TrackSnapshot(from: $0) }
        guard let first = snaps.first else { return }
        playback.playTrack(first, context: snaps, from: .album)
    }

    private func playImport(_ imp: YouTubeImport) {
        let snaps = (imp.items ?? []).sorted { $0.order < $1.order }
            .compactMap { $0.track }
            .map { TrackSnapshot(from: $0) }
        guard let first = snaps.first else { return }
        playback.playTrack(first, context: snaps, from: .import)
    }

    private func importArtwork(_ imp: YouTubeImport) -> ArtworkSource {
        if let urlStr = imp.artworkUrl, let url = URL(string: urlStr) {
            return .remote(url)
        }
        if let first = (imp.items ?? []).sorted(by: { $0.order < $1.order }).first,
           let url = YouTubeThumbnail.url(videoId: first.youTubeId) {
            return .remote(url)
        }
        return .placeholder
    }

    // MARK: - YouTube 辅助

    private func loadTrending() {
        trendingTask?.cancel()
        trendingError = nil
        // 查询种子:若用户有播放记录,用最常听的艺术家做个性化种子;否则用热门音乐。
        let seed: String
        if let artist = library.topArtistName() {
            seed = "\(artist) top songs"
        } else {
            seed = "trending music 2026"
        }
        let limit = 12

        // stale-while-revalidate(spec §16/§17):先展示缓存(即使 stale)立即上屏。
        if let cached = YTDlpSearchCache.default.get(query: seed, limit: limit) {
            ytTrending = cached.value
            trendingLoading = false
            PerfTrace.event("home.firstCachedContent")
            // 新鲜命中:跳过 yt-dlp spawn(spec §21)。
            if YTDlpSearchCache.default.isFresh(query: seed, limit: limit) {
                PerfTrace.event("home.firstRemoteContent")
                return
            }
            // stale:保留缓存内容,后台刷新。
        } else {
            trendingLoading = true
        }

        trendingTask = Task {
            do {
                let results = try await ytSearch.search(query: seed, limit: limit)
                guard !Task.isCancelled else { return }
                ytTrending = results
                PerfTrace.event("home.firstRemoteContent")
            } catch {
                guard !Task.isCancelled else { return }
                trendingError = tr("Failed to load Top Picks", "加载为你推荐失败")
            }
            trendingLoading = false
        }
    }

    private func playYouTube(_ entry: YTDlpBridge.YTDlpPlaylistEntry) async {
        do {
            let snap = try await ytSearch.importAsTrack(entry: entry)
            let context = TrackSnapshot.playbackContext(
                playing: snap, youTubeEntries: ytTrending)
            playback.playTrack(snap, context: context, from: .search)
        } catch {
            // 静默
        }
    }

    private func sectionItems(for card: YouTubeDiscoveryCard) -> [YTDlpBridge.YTDlpPlaylistEntry] {
        let section = homeDiscovery.sections.first { section in
            section.items.contains { item in
                if case .youTube(let c) = item { return c.id == card.id }
                return false
            }
        }
        return (section?.items ?? []).compactMap { item in
            if case .youTube(let c) = item {
                return YTDlpBridge.YTDlpPlaylistEntry(
                    id: c.id, title: c.title, uploader: c.uploader, duration: c.duration)
            }
            return nil
        }
    }
}

/// YouTube 热门单曲卡片:缩略图 + 标题 + 频道。
struct YouTubeTrendingCard: View {
    let entry: YTDlpBridge.YTDlpPlaylistEntry
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 6) {
                CachedAsyncImage(url: YouTubeThumbnail.url(videoId: entry.id)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(BrandColors.surface)
                        .overlay(Image(systemName: "music.note").font(.title))
                }
                .frame(width: 160, height: 90)
                .clipped().cornerRadius(8)

                Text(entry.title).font(.subheadline).lineLimit(1)
                    .foregroundStyle(BrandColors.textPrimary)
                Text(entry.uploader ?? "YouTube").font(.caption).lineLimit(1)
                    .foregroundStyle(BrandColors.textSecondary)
            }
            .frame(width: 160)
        }
        .buttonStyle(.plain)
    }
}

/// Phase D3 — Home 发现流 YouTube 卡片:缩略图 + 标题 + 频道(16:9)。
struct HomeDiscoveryCardView: View {
    let card: YouTubeDiscoveryCard
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 6) {
                CachedAsyncImage(
                    url: card.thumbnailURL.flatMap(URL.init(string:))) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(BrandColors.surface)
                        .overlay(Image(systemName: "music.note").font(.title))
                }
                .frame(width: 160, height: 90)
                .clipped().cornerRadius(8)

                Text(card.title).font(.subheadline).lineLimit(1)
                    .foregroundStyle(BrandColors.textPrimary)
                Text(card.uploader ?? "YouTube").font(.caption).lineLimit(1)
                    .foregroundStyle(BrandColors.textSecondary)
            }
            .frame(width: 160)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(card.title) — \(card.uploader ?? "YouTube")")
    }
}