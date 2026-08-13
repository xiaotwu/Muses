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
    @Query(sort: \YouTubeImport.importedAt, order: .reverse) private var ytImports: [YouTubeImport]
    @State private var heroGradient: [Color] = [BrandColors.background, BrandColors.surface]
    @State private var ytTrending: [YTDlpBridge.YTDlpPlaylistEntry] = []
    @State private var trendingLoading = false
    @State private var trendingError: String?

    private var albums: [Album] { library.allAlbums() }

    /// Hero 专辑:优先选最近播放的,否则最近添加的,否则第一个。
    private var heroAlbum: Album? {
        library.mostRecentlyPlayedAlbum() ?? albums.first
    }

    /// 最近添加的专辑(按曲目 addedAt 降序,前 20)。
    private var recentlyAdded: [Album] {
        albums.sorted { a, b in
            let aDate = a.tracks.map(\.addedAt).max() ?? .distantPast
            let bDate = b.tracks.map(\.addedAt).max() ?? .distantPast
            return aDate > bDate
        }.prefix(20).map { $0 }
    }

    /// 钉选专辑。
    private var pinnedAlbums: [Album] { library.pinnedAlbums() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Hero
                if let hero = heroAlbum {
                    heroSection(hero)
                }

                // 最近添加
                if !recentlyAdded.isEmpty {
                    horizontalSection(
                        title: tr("Recently Added", "最近添加"),
                        albums: recentlyAdded
                    )
                }

                // 钉选
                if !pinnedAlbums.isEmpty {
                    horizontalSection(
                        title: tr("Pinned", "钉选"),
                        albums: pinnedAlbums
                    )
                }

                // YouTube 热门搜索
                youtubeTrendingSection

                // 已导入的 YouTube 歌单
                if !ytImports.isEmpty {
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
            updateGradient()
            loadTrending()
        }
        .onChange(of: heroAlbum?.id) { _, _ in updateGradient() }
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

    // MARK: - 横向滚动区

    private func horizontalSection(title: String, albums: [Album]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(BrandColors.textPrimary)
                .padding(.horizontal, 24)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(albums, id: \.id) { album in
                        VStack(alignment: .leading, spacing: 6) {
                            let art = album.artworkHash.flatMap { ArtworkCache.default.path(forHash: $0) }
                                .map { NSImage(byReferencing: $0) }
                            if let img = art {
                                Image(nsImage: img).resizable().scaledToFill()
                                    .frame(width: 140, height: 140)
                                    .clipped().cornerRadius(8)
                            } else {
                                RoundedRectangle(cornerRadius: 8).fill(BrandColors.surface)
                                    .frame(width: 140, height: 140)
                                    .overlay(Image(systemName: "music.note").font(.title))
                            }
                            Text(album.title).font(.caption).lineLimit(1)
                                .foregroundStyle(BrandColors.textPrimary)
                            Text(album.albumArtist).font(.caption2).lineLimit(1)
                                .foregroundStyle(BrandColors.textSecondary)
                        }
                        .frame(width: 140)
                        .onTapGesture { selectedAlbum = album }
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    // MARK: - YouTube 热门搜索

    @ViewBuilder
    private var youtubeTrendingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("YouTube Trending", "YouTube 热门"))
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(BrandColors.textPrimary)
                .padding(.horizontal, 24)

            if trendingLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else if let err = trendingError {
                Text(err).font(.caption).foregroundStyle(BrandColors.textSecondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else if !ytTrending.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(ytTrending.prefix(10), id: \.id) { entry in
                            YouTubeTrendingCard(entry: entry) {
                                Task { await playYouTube(entry) }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
    }

    // MARK: - 已导入的 YouTube 歌单

    @ViewBuilder
    private var youtubeImportsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Imported Playlists", "已导入歌单"))
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(BrandColors.textPrimary)
                .padding(.horizontal, 24)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(ytImports.prefix(10), id: \.id) { imp in
                        YouTubeImportCardSmall(imp: imp)
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    // MARK: - 全部专辑

    private var allAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("All Albums", "全部专辑"))
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(BrandColors.textPrimary)
                .padding(.horizontal, 24)

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

    private func updateGradient() {
        guard let album = heroAlbum,
              let hash = album.artworkHash,
              let path = ArtworkCache.default.path(forHash: hash),
              let img = NSImage(contentsOf: path) else { return }
        let colors = AlbumArtworkExtractor.dominantColors(img, count: 4)
        heroGradient = colors.map { Color(nsColor: $0) } + [BrandColors.background]
    }

    private func playAlbum(_ album: Album) {
        let tracks = library.tracks(in: album)
        let snaps = tracks.map { TrackSnapshot(from: $0) }
        guard let first = snaps.first else { return }
        playback.playTrack(first, context: snaps, from: .album)
    }

    // MARK: - YouTube 辅助

    private func loadTrending() {
        guard ytTrending.isEmpty && !trendingLoading else { return }
        trendingLoading = true
        trendingError = nil
        Task {
            do {
                let results = try await ytSearch.search(query: "热门音乐 trending music 2024", limit: 12)
                ytTrending = results
            } catch {
                trendingError = tr("Failed to load YouTube trending", "加载 YouTube 热门失败")
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

/// YouTube 热门单曲卡片:缩略图 + 标题 + 频道。
struct YouTubeTrendingCard: View {
    let entry: YTDlpBridge.YTDlpPlaylistEntry
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 6) {
                AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(entry.id)/hqdefault.jpg")) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() }
                    else {
                        Rectangle().fill(BrandColors.surface)
                            .overlay(Image(systemName: "music.note").font(.title))
                    }
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
                        AsyncImage(url: url) { phase in
                            if let img = phase.image { img.resizable().scaledToFill() }
                            else { thumbnailFallback }
                        }
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
                AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(first.youTubeId)/hqdefault.jpg")) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() }
                    else { placeholder }
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