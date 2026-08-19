import SwiftUI

/// New 页面:本地推荐算法 — 基于播放历史 + 收藏曲目的离线推荐。
///
/// 三类推荐:
/// - **因为你听过**(Because You Listened):播放最多艺术家的其他专辑
/// - **未探索**(Unplayed Gems):尚未播放过的专辑
/// - **基于收藏**(From Liked):收藏曲目艺术家的其他专辑
struct NewView: View {
    @Binding var selectedAlbum: Album?
    @Environment(RecommendationService.self) private var recommendation
    @Environment(SituationalRecommendationService.self) private var situational
    @Environment(LibraryService.self) private var library
    @Environment(PlaybackService.self) private var playback
    @Environment(FocusService.self) private var focus
    /// nil = 尚未计算完成(显示占位);非 nil = 已计算。
    @State private var recs: RecommendationService.Recommendations? = nil
    @State private var computeTask: Task<Void, Never>?
    // Phase D5 — 情境化推荐区段(ffSituationalNew 开启时使用)。
    @State private var situationalSections: [SituationalSection] = []
    @State private var situationalTask: Task<Void, Never>?
    @State private var playingAlbumID: UUID?
    @State private var playingArtistID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Phase D6 — Apple Music 风格大标题(~30pt),与 Home 节奏一致。
                // 保留 "New" 名称(用户确认决定,本阶段不改名 "For You")。
                Text(tr("New", "发现"))
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(BrandColors.textPrimary)
                    .padding(.horizontal, 24)

                if situational.isEnabled {
                    situationalBody
                } else {
                    legacyBody
                }
            }
            .padding(.bottom, 100)
        }
        .background(BrandColors.background)
        .onAppear { scheduleCompute(); refreshPlayingCollection() }
        .onDisappear {
            computeTask?.cancel()
            situationalTask?.cancel()
        }
        .onChange(of: library.likedRevision) { _, _ in scheduleCompute() }
        .onChange(of: library.metadataRevision) { _, _ in scheduleCompute() }
        .onChange(of: library.playRevision) { _, _ in scheduleCompute() }
        .onChange(of: playback.state.track?.id) { _, _ in refreshPlayingCollection() }
    }

    // MARK: - Phase D5/D6:情境化推荐(D4 原语呈现)

    @ViewBuilder
    private var situationalBody: some View {
        if situationalSections.isEmpty {
            // 计算中或无足够信号:骨架占位(无 spinner,§15),与 Home 冷启一致。
            VStack(alignment: .leading, spacing: 32) {
                skeletonSection
                skeletonSection
            }
        } else {
            ForEach(situationalSections) { section in
                situationalSection(section)
            }
        }
    }

    private var skeletonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SkeletonBlock(width: 200, height: 22)
                .padding(.horizontal, 24)
            ResponsiveCarousel(cardSize: 140) {
                ForEach(0..<5, id: \.self) { _ in SkeletonCard(size: 140, aspect: .square) }
            }
        }
    }

    @ViewBuilder
    private func situationalSection(_ section: SituationalSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: section.title, subtitle: section.subtitle)
            ResponsiveCarousel(cardSize: MusicObjectMetrics.albumRail) {
                ForEach(section.items, id: \.id) { snap in
                    AlbumObjectView(
                        title: snap.title,
                        subtitle: snap.artist,
                        artwork: ArtworkSource.resolve(for: snap),
                        size: MusicObjectMetrics.albumRail,
                        role: .play,
                        nowPlayingID: snap.id,
                        showsHoverPlay: true,
                        onSelect: {},
                        onPlay: { playback.playTrack(snap, context: section.items, from: .songs) }
                    )
                }
            }
        }
    }

    // MARK: - Legacy(RecommendationService,ffSituationalNew 关闭时)

    @ViewBuilder
    private var legacyBody: some View {
        if focus.isActive {
                    // 专注模式:抑制发现表面(Final Spec §10.9),展示专注提示而非推荐。
                    EmptyStateView(
                        icon: "brain.head.profile",
                        title: tr("Focusing", "专注中"),
                        subtitle: tr("Recommendations are hidden while you focus. End Focus Mode to see picks.",
                                       "专注时隐藏推荐。结束专注模式以查看推荐。")
                    )
                    .padding(.top, 60)
                } else if let r = recs, r.hasContent {
                    if !r.becauseYouListened.isEmpty {
                        recSection(
                            title: tr("Because You Listened", "因为你听过"),
                            subtitle: tr("More from your most-played artists",
                                          "来自你播放最多的艺术家"),
                            albums: r.becauseYouListened
                        )
                    }
                    if !r.unplayedGems.isEmpty {
                        recSection(
                            title: tr("Unplayed Gems", "未探索"),
                            subtitle: tr("Albums in your library you haven't played yet",
                                          "资料库中尚未播放的专辑"),
                            albums: r.unplayedGems
                        )
                    }
                    if !r.fromLiked.isEmpty {
                        recSection(
                            title: tr("From Your Liked Songs", "基于收藏"),
                            subtitle: tr("Artists you've liked, more to explore",
                                          "你收藏的艺术家,更多探索"),
                            albums: r.fromLiked
                        )
                    }
                } else if recs == nil {
                    // 计算中:轻量占位,不用 spinner 避免视觉跳动。
                    EmptyStateView(
                        icon: "sparkles",
                        title: tr("Finding picks for you…", "正在为你挑选…"),
                        subtitle: nil
                    )
                    .padding(.top, 60)
                } else {
                    EmptyStateView(
                        icon: "sparkles",
                        title: tr("Play More to Get Recommendations", "播放更多以获取推荐"),
                        subtitle: tr("Recommendations are based on your play history and liked songs. Play and like some tracks to get personalized picks.",
                                       "推荐基于你的播放历史与收藏。播放并收藏一些曲目以获得个性化推荐。")
                    )
                    .padding(.top, 60)
                }
    }

    /// 异步触发推荐计算(后台离线计算,完成后回主线程赋值)。
    /// 重复调用会取消上一个进行中的任务,避免排队。
    /// Phase D5:ffSituationalNew 开启时,并行计算情境化推荐。
    private func scheduleCompute() {
        computeTask?.cancel()
        let service = recommendation
        computeTask = Task { @MainActor in
            let result = await service.compute()
            guard !Task.isCancelled else { return }
            recs = result
        }
        if situational.isEnabled {
            situationalTask?.cancel()
            let svc = situational
            situationalTask = Task { @MainActor in
                let sections = await svc.compute()
                guard !Task.isCancelled else { return }
                situationalSections = sections
            }
        } else {
            situationalSections = []
        }
    }

    // MARK: - 推荐区(D4 原语呈现;legacy 路径)

    @ViewBuilder
    private func recSection(title: String, subtitle: String, albums: [Album]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title, subtitle: subtitle)
            ResponsiveCarousel(cardSize: MusicObjectMetrics.albumRail) {
                ForEach(albums, id: \.id) { album in
                    AlbumObjectView(
                        title: album.title,
                        subtitle: album.albumArtist,
                        artwork: ArtworkSource.localHash(album.artworkHash),
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

    private func refreshPlayingCollection() {
        let id = playback.state.track?.id
        playingAlbumID = id.flatMap { library.track(by: $0)?.album?.id }
        playingArtistID = id.flatMap { library.track(by: $0)?.artistRef?.id }
    }

    private func playAlbum(_ album: Album) {
        let snaps = library.tracks(in: album).map { TrackSnapshot(from: $0) }
        guard let first = snaps.first else { return }
        playback.playTrack(first, context: snaps, from: .album)
    }
}