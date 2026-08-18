import Foundation

/// 基于 yt-dlp `ytsearch` 的默认 Home 发现 provider(Phase D3)。
///
/// 架构(用户确认决定):**混合远程发现**——以外部 YouTube 音乐世界发现为主,
/// 用户历史仅作轻度排序信号。provider 根据 `HomeDiscoveryInput` 生成若干主题化
/// `ytsearch` 查询,每个 section 独立产出;单 section 失败返回 `.failed`,不毒化其它。
///
/// 区段标题由 provider 生成(不硬编码于视图)。历史轻度排序:结果按 uploader 与
/// 用户 top/最近艺术家名的重叠度稳定重排。
///
/// 搜索入口以闭包注入,便于测试桩替换,且解耦 `YTDlpBridge`(@MainActor)。
@MainActor
final class YTDlpDiscoveryProvider: HomeDiscoveryProvider {

    /// yt-dlp 搜索入口。默认桥接 `YouTubeSearchService.search`/`YTDlpBridge.searchYouTube`。
    /// 抛错时该 section 标 `.failed`。
    private let search: (String, Int) async throws -> [YTDlpBridge.YTDlpPlaylistEntry]
    /// 每个 section 的结果上限。
    private let perSectionLimit: Int
    /// 结果裁剪到展示上限。
    private let displayLimit: Int

    init(perSectionLimit: Int = 12,
         displayLimit: Int = 10,
         search: @escaping (String, Int) async throws -> [YTDlpBridge.YTDlpPlaylistEntry]) {
        self.perSectionLimit = perSectionLimit
        self.displayLimit = displayLimit
        self.search = search
    }

    func sections(for input: HomeDiscoveryInput) async -> [HomeSection] {
        // 1. 由 input 派生主题化查询 plan(标题 + 查询串)。标题在此生成,非视图硬编码。
        let plans = sectionPlans(for: input)
        // 2. 每个 section 独立 async;TaskGroup 有限并发(plan 数固定 ≤ 5,天然有界)。
        let results: [(Int, HomeSection)] = await withTaskGroup(of: (Int, HomeSection).self) { group in
            for (idx, plan) in plans.enumerated() {
                group.addTask { [self] in
                    let section = await self.runSection(plan: plan, input: input)
                    return (idx, section)
                }
            }
            var out: [(Int, HomeSection)] = []
            for await pair in group { out.append(pair) }
            return out
        }
        return results.sorted { $0.0 < $1.0 }.map(\.1)
    }

    // MARK: - Section planning

    /// 区段计划:稳定 id + 本地化标题 + 主题查询串。
    private struct SectionPlan: Sendable {
        let id: String
        let title: String
        let subtitle: String?
        let query: String
    }

    private func sectionPlans(for input: HomeDiscoveryInput) -> [SectionPlan] {
        var plans: [SectionPlan] = []

        // (a) 最常听艺术家的 top songs —— 个性化锚点。
        if let artist = input.topArtistNames.first {
            plans.append(SectionPlan(
                id: "top-artist",
                title: tr("Top songs by \(artist)", "\(artist) 的热门歌曲"),
                subtitle: tr("From YouTube", "来自 YouTube"),
                query: "\(artist) top songs"))
        }

        // (b) 时段主题 —— 由 provider 据 timeBand 生成标题与查询。
        let band = input.timeBand
        let bandPlan: SectionPlan
        switch band {
        case .morning:
            bandPlan = SectionPlan(
                id: "time-of-day",
                title: tr("Morning picks", "清晨精选"),
                subtitle: tr("Ease into the day", "从容开启一天"),
                query: "morning playlist chill")
        case .afternoon:
            bandPlan = SectionPlan(
                id: "time-of-day",
                title: tr("Afternoon rotation", "午后轮播"),
                subtitle: tr("Keep moving", "保持节奏"),
                query: "afternoon pop hits")
        case .evening:
            bandPlan = SectionPlan(
                id: "time-of-day",
                title: tr("Evening chill", "傍晚放松"),
                subtitle: tr("Wind down", "慢下来"),
                query: "evening chill music")
        case .lateNight:
            bandPlan = SectionPlan(
                id: "time-of-day",
                title: tr("Late-night picks", "深夜精选"),
                subtitle: tr("For the quiet hours", "献给安静的时刻"),
                query: "late night ambient music")
        }
        plans.append(bandPlan)

        // (c) 收藏艺术家的 essentials —— 轻度历史信号驱动的发现。
        if let liked = input.likedArtistNames.first, liked != input.topArtistNames.first {
            plans.append(SectionPlan(
                id: "from-liked",
                title: tr("Because you like \(liked)", "因为你喜欢 \(liked)"),
                subtitle: tr("From YouTube", "来自 YouTube"),
                query: "\(liked) essentials playlist"))
        }

        // (d) 通用 trending —— 保底发现,始终存在以确保 Home 有远程内容。
        plans.append(SectionPlan(
            id: "trending",
            title: tr("Trending now", "正在流行"),
            subtitle: tr("From YouTube", "来自 YouTube"),
            query: "trending music \(currentYear)"))

        return plans
    }

    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }

    // MARK: - Per-section execution

    private func runSection(plan: SectionPlan, input: HomeDiscoveryInput) async -> HomeSection {
        do {
            let entries = try await search(plan.query, perSectionLimit)
            let cards = entries.map(YouTubeDiscoveryCard.init(entry:))
            let ranked = lightlyRank(cards, input: input).prefix(displayLimit).map { $0 }
            return HomeSection(
                id: plan.id,
                title: plan.title,
                subtitle: plan.subtitle,
                kind: .youTubeCarousel,
                items: ranked.map { .youTube($0) },
                status: .loaded)
        } catch {
            return HomeSection(
                id: plan.id,
                title: plan.title,
                subtitle: plan.subtitle,
                kind: .youTubeCarousel,
                items: [],
                status: .failed(nil))
        }
    }

    /// 轻度历史排序:uploader 命中用户 top/最近艺术家名的卡片稳定前置。
    /// 不改变未命中卡片的相对顺序(稳定)。
    private func lightlyRank(_ cards: [YouTubeDiscoveryCard],
                              input: HomeDiscoveryInput) -> [YouTubeDiscoveryCard] {
        let signals = Set((input.topArtistNames + input.recentlyPlayedArtistNames)
            .map { $0.lowercased() })
        guard !signals.isEmpty else { return cards }
        return cards.stableSort { card in
            // 命中得 1,未命中得 0;stableSort 保持原序内稳定。
            if let up = card.uploader?.lowercased(), signals.contains(up) { return 1 }
            return 0
        }
    }
}

/// 稳定排序:按 `score` 降序,相等保持原序。
private extension Array {
    func stableSort(by score: (Element) -> Int) -> [Element] {
        indexed().sorted { a, b in
            let sa = score(a.element), sb = score(b.element)
            return sa != sb ? sa > sb : a.index < b.index
        }.map(\.element)
    }
    private func indexed() -> [(index: Int, element: Element)] {
        enumerated().map { (index: $0.offset, element: $0.element) }
    }
}