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

    /// Hero 专辑:优先选最近播放的,否则最近添加的,否则第一个。
    /// 现在读取缓存的 `heroAlbum`,由 `refreshLibrarySnapshot()` 维护。

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Phase D4 — Apple Music 风格大标题(~30pt)。保留既有信息架构与行为。
                Text(tr("Home", "首页"))
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(BrandColors.textPrimary)
                    .padding(.horizontal, 24)

                // Hero
                if let hero = heroAlbum {
                    heroSection(hero)
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

                // 最近添加
                if !recentlyAdded.isEmpty {
                    horizontalSection(
                        title: tr("Recently Added", "最近添加"),
                        albums: recentlyAdded
                    )
                }

                // 钉选
                if !pinnedAlbumsCache.isEmpty {
                    horizontalSection(
                        title: tr("Pinned", "钉选"),
                        albums: pinnedAlbumsCache
                    )
                }

                // 已导入的 YouTube 歌单(ffDiscovery 关时在此呈现;开时由发现流托管)。
                if !homeDiscovery.isEnabled, !ytImports.isEmpty {
                    youtubeImportsSection
                }

                // 全部专辑
                if !albums.isEmpty {
                    allAlbumsSection
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 100)
        }
        .background(
            LinearGradient(colors: heroGradient,
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.4), value: heroAlbum?.id)
        )
        .onAppear {
            PerfTrace.event("home.appear")
            // 将资料库快照从同步 appear 路径延迟到首帧绘制后(spec §15/§16),
            // 让骨架/缓存内容先上屏。
            Task { @MainActor in
                refreshLibrarySnapshot()
                PerfTrace.event("home.firstCachedContent")
            }
            updateGradientAsync()
            loadTrending()
            // Phase D3:动态发现流 cache-first 加载(仅 ffDiscovery 开启时生效)。
            homeDiscovery.load()
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

    // MARK: - Hero

    private func heroSection(_ album: Album) -> some View {
        HStack(spacing: 24) {
            // 大封面
            let art = album.artworkHash.flatMap { ArtworkCache.default.path(forHash: $0) }
                .map { NSImage(byReferencing: $0) }
            if let img = art {
                Image(nsImage: img).resizable().scaledToFill()
                    .frame(width: 200, height: 200)
                    .clipped().cornerRadius(12)
                    .shadow(radius: 20)
            } else {
                RoundedRectangle(cornerRadius: 12).fill(BrandColors.surface)
                    .frame(width: 200, height: 200)
                    .overlay(Image(systemName: "music.note").font(.largeTitle))
                    .shadow(radius: 20)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(tr("FEATURED", "推荐"))
                    .font(.caption).fontWeight(.bold)
                    .foregroundStyle(BrandColors.textSecondary)
                    .tracking(1.5)
                Text(album.title)
                    .font(.largeTitle).fontWeight(.bold)
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(2)
                Text(album.albumArtist)
                    .font(.title3)
                    .foregroundStyle(BrandColors.textSecondary)
                if let year = album.year {
                    Text(String(year))
                        .font(.subheadline)
                        .foregroundStyle(BrandColors.textSecondary)
                }
                Button {
                    playAlbum(album)
                } label: {
                    Label(tr("Play", "播放"), systemImage: "play.fill")
                        .padding(.horizontal, 16).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColors.magenta)
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .onTapGesture { selectedAlbum = album }
    }

    // MARK: - 横向滚动区(Phase D4:复用 SectionHeader + ResponsiveCarousel + DiscoveryCard)

    private func horizontalSection(title: String, albums: [Album]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
            ResponsiveCarousel(cardSize: 150) {
                ForEach(albums, id: \.id) { album in
                    DiscoveryCard(
                        title: album.title,
                        subtitle: album.albumArtist,
                        artworkPath: album.artworkHash.flatMap { ArtworkCache.default.path(forHash: $0) },
                        size: 150, aspect: .square,
                        onTap: { selectedAlbum = album })
                }
            }
        }
    }

    // MARK: - Recently Played(本地 + YouTube 播放历史)

    @ViewBuilder
    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: tr("Recently Played", "最近播放"))
            ResponsiveCarousel(cardSize: 130) {
                ForEach(recentlyPlayed, id: \.id) { snap in
                    RecentTrackCard(snap: snap) {
                        playback.playTrack(snap, context: recentlyPlayed, from: .recently)
                    }
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
                ResponsiveCarousel(cardSize: 160) {
                    ForEach(ytTrending.prefix(10), id: \.id) { entry in
                        YouTubeTrendingCard(entry: entry) {
                            Task { await playYouTube(entry) }
                        }
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
            ResponsiveCarousel(cardSize: 150) {
                ForEach(ytImports.prefix(10), id: \.id) { imp in
                    YouTubeImportCardSmall(imp: imp)
                }
            }
        }
    }

    // MARK: - Phase D3:动态发现流

    /// 渲染 `HomeDiscoveryService.sections`:每 section 独立状态(cache-first + per-section failure)。
    /// 标题/副标题来自 provider,视图不硬编码 YouTube Music 区段名。
    @ViewBuilder
    private var discoveryFeedSection: some View {
        VStack(alignment: .leading, spacing: 32) {
            ForEach(homeDiscovery.sections) { section in
                discoverySection(section)
            }
        }
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
                    ResponsiveCarousel(cardSize: 160) {
                        ForEach(0..<5, id: \.self) { _ in SkeletonCard(size: 160, aspect: .wide169) }
                    }
                case .failed(let msg):
                    if homeDiscovery.isRefreshing && retryingIDs.contains(section.id) {
                        ResponsiveCarousel(cardSize: 160) {
                            ForEach(0..<5, id: \.self) { _ in SkeletonCard(size: 160, aspect: .wide169) }
                        }
                    } else {
                        VStack(spacing: 8) {
                            Text(msg ?? tr("Couldn’t load this section", "无法加载该区段"))
                                .font(.caption).foregroundStyle(BrandColors.textSecondary)
                            Button(tr("Retry", "重试")) {
                                retryingIDs.insert(section.id)
                                homeDiscovery.reload()
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                    }
                case .loaded, .idle:
                    ResponsiveCarousel(cardSize: 160) {
                        ForEach(section.items) { item in
                            if case .youTube(let card) = item {
                                HomeDiscoveryCardView(card: card) {
                                    Task { await playYouTubeCard(card) }
                                }
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
            playback.playTrack(snap, context: [snap], from: .search)
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
                    AlbumCard(album: album)
                        .onTapGesture { selectedAlbum = album }
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

    private func playAlbum(_ album: Album) {
        let tracks = library.tracks(in: album)
        let snaps = tracks.map { TrackSnapshot(from: $0) }
        guard let first = snaps.first else { return }
        playback.playTrack(first, context: snaps, from: .album)
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
            playback.playTrack(snap, context: [snap], from: .search)
        } catch {
            // 静默
        }
    }
}

/// 最近播放的曲目卡片:方形封面 + 标题 + 艺术家(本地用 artworkHash,YouTube 用缩略图)。
struct RecentTrackCard: View {
    let snap: TrackSnapshot
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 6) {
                artwork
                    .frame(width: 120, height: 120)
                    .clipped().cornerRadius(8)
                Text(snap.title).font(.caption).lineLimit(1)
                    .foregroundStyle(BrandColors.textPrimary)
                Text(snap.artist).font(.caption2).lineLimit(1)
                    .foregroundStyle(BrandColors.textSecondary)
            }
            .frame(width: 120)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var artwork: some View {
        if let hash = snap.artworkHash,
           let path = ArtworkCache.default.path(forHash: hash) {
            Image(nsImage: NSImage(byReferencing: path)).resizable().scaledToFill()
        } else if let vid = snap.youTubeId,
                  let url = URL(string: "https://i.ytimg.com/vi/\(vid)/hqdefault.jpg") {
            CachedAsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { placeholder }
        } else if let urlStr = snap.artworkUrl, let url = URL(string: urlStr) {
            CachedAsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { placeholder }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8).fill(BrandColors.surface)
            .overlay(Image(systemName: "music.note").font(.title)
                .foregroundStyle(BrandColors.textSecondary.opacity(0.5)))
    }
}

/// YouTube 热门单曲卡片:缩略图 + 标题 + 频道。
struct YouTubeTrendingCard: View {
    let entry: YTDlpBridge.YTDlpPlaylistEntry
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 6) {
                CachedAsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(entry.id)/hqdefault.jpg")) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(BrandColors.surface)
                        .overlay(Image(systemName: "music.note").font(.title))
                }
                .frame(width: 160, height: 90)
                .clipped().cornerRadius(8)

                Text(entry.title).font(.caption).lineLimit(1)
                    .foregroundStyle(BrandColors.textPrimary)
                Text(entry.uploader ?? "YouTube").font(.caption2).lineLimit(1)
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

                Text(card.title).font(.caption).lineLimit(1)
                    .foregroundStyle(BrandColors.textPrimary)
                Text(card.uploader ?? "YouTube").font(.caption2).lineLimit(1)
                    .foregroundStyle(BrandColors.textSecondary)
            }
            .frame(width: 160)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(card.title) — \(card.uploader ?? "YouTube")")
    }
}

/// 已导入 YouTube 歌单的迷你卡片:封面 + 标题 + 频道。
struct YouTubeImportCardSmall: View {
    let imp: YouTubeImport

    private var items: [YouTubeImportItem] {
        (imp.items ?? []).sorted { $0.order < $1.order }
    }

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .musesNavigateYouTubeImport, object: imp)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let urlStr = imp.artworkUrl, let url = URL(string: urlStr) {
                        CachedAsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { thumbnailFallback }
                    } else {
                        thumbnailFallback
                    }
                }
                .frame(width: 140, height: 140)
                .clipped().cornerRadius(8)

                Text(imp.title).font(.caption).lineLimit(1)
                    .foregroundStyle(BrandColors.textPrimary)
                Text(imp.channel).font(.caption2).lineLimit(1)
                    .foregroundStyle(BrandColors.textSecondary)
            }
            .frame(width: 140)
        }
        .buttonStyle(.plain)
    }

    private var thumbnailFallback: some View {
        Group {
            if let first = items.first {
                CachedAsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(first.youTubeId)/hqdefault.jpg")) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
    }
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8).fill(BrandColors.surface)
            .overlay(Image(systemName: "music.note.list")
                .font(.title).foregroundStyle(BrandColors.textSecondary.opacity(0.5)))
    }
}