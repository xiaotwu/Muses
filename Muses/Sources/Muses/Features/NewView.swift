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
        .onAppear { scheduleCompute() }
        .onDisappear {
            computeTask?.cancel()
            situationalTask?.cancel()
        }
        .onChange(of: library.likedRevision) { _, _ in scheduleCompute() }
        .onChange(of: library.metadataRevision) { _, _ in scheduleCompute() }
        .onChange(of: library.playRevision) { _, _ in scheduleCompute() }
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
            ResponsiveCarousel(cardSize: 140) {
                ForEach(section.items, id: \.id) { snap in
                    situationalTrackCard(snap)
                }
            }
        }
    }

    @ViewBuilder
    private func situationalTrackCard(_ snap: TrackSnapshot) -> some View {
        Button {
            playback.playTrack(snap, context: [snap], from: .songs)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let hash = snap.artworkHash,
                       let path = ArtworkCache.default.path(forHash: hash) {
                        Image(nsImage: NSImage(byReferencing: path)).resizable().scaledToFill()
                    } else if let vid = snap.youTubeId,
                              let url = URL(string: "https://i.ytimg.com/vi/\(vid)/hqdefault.jpg") {
                        CachedAsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: {
                            RoundedRectangle(cornerRadius: 8).fill(BrandColors.surface)
                                .overlay(Image(systemName: "music.note").font(.title))
                        }
                    } else if let urlStr = snap.artworkUrl, let url = URL(string: urlStr) {
                        CachedAsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: {
                            RoundedRectangle(cornerRadius: 8).fill(BrandColors.surface)
                                .overlay(Image(systemName: "music.note").font(.title))
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 8).fill(BrandColors.surface)
                            .overlay(Image(systemName: "music.note").font(.title)
                                .foregroundStyle(BrandColors.textSecondary.opacity(0.5)))
                    }
                }
                .frame(width: 140, height: 140)
                .clipped().cornerRadius(8)

                Text(snap.title).font(.caption).lineLimit(1)
                    .foregroundStyle(BrandColors.textPrimary)
                Text(snap.artist).font(.caption2).lineLimit(1)
                    .foregroundStyle(BrandColors.textSecondary)
            }
            .frame(width: 140)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(snap.title) — \(snap.artist)")
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
}