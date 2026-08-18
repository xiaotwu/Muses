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
    @Environment(LibraryService.self) private var library
    @Environment(FocusService.self) private var focus
    /// nil = 尚未计算完成(显示占位);非 nil = 已计算。
    @State private var recs: RecommendationService.Recommendations? = nil
    @State private var computeTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // 页面标题
                Text(tr("New for You", "为你推荐"))
                    .font(.largeTitle).fontWeight(.bold)
                    .foregroundStyle(BrandColors.textPrimary)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)

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
            .padding(.bottom, 100)
        }
        .background(BrandColors.background)
        .onAppear { scheduleCompute() }
        .onDisappear { computeTask?.cancel() }
        .onChange(of: library.likedRevision) { _, _ in scheduleCompute() }
        .onChange(of: library.metadataRevision) { _, _ in scheduleCompute() }
    }

    /// 异步触发推荐计算(后台离线计算,完成后回主线程赋值)。
    /// 重复调用会取消上一个进行中的任务,避免排队。
    private func scheduleCompute() {
        computeTask?.cancel()
        let service = recommendation
        computeTask = Task { @MainActor in
            let result = await service.compute()
            guard !Task.isCancelled else { return }
            recs = result
        }
    }

    // MARK: - 推荐区

    @ViewBuilder
    private func recSection(title: String, subtitle: String, albums: [Album]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2).fontWeight(.bold)
                    .foregroundStyle(BrandColors.textPrimary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(BrandColors.textSecondary)
            }
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
}