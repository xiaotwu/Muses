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
    private let fetchPlaylist: ((String) async throws -> [YTDlpBridge.YTDlpPlaylistEntry])?
    /// 每个 section 的结果上限。
    private let perSectionLimit: Int
    /// 结果裁剪到展示上限。
    private let displayLimit: Int

    init(perSectionLimit: Int = 12,
         displayLimit: Int = 10,
         fetchPlaylist: ((String) async throws -> [YTDlpBridge.YTDlpPlaylistEntry])? = nil,
         search: @escaping (String, Int) async throws -> [YTDlpBridge.YTDlpPlaylistEntry]) {
        self.perSectionLimit = perSectionLimit
        self.displayLimit = displayLimit
        self.fetchPlaylist = fetchPlaylist
        self.search = search
    }

    func fetch(for input: HomeDiscoveryInput) async -> HomeFetchResult {
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
            var sharedFailure: String?
            for await pair in group {
                out.append(pair)
                if case .failed(let msg) = pair.1.status, let msg,
                   YouTubeIdentity.isSharedDiscoveryFailure(msg) {
                    sharedFailure = msg
                    group.cancelAll()
                }
            }
            if let sharedFailure {
                out = out.map { idx, section in
                    if case .failed(let msg) = section.status, msg == nil {
                        return (idx, HomeSection(
                            id: section.id, title: section.title, subtitle: section.subtitle,
                            kind: section.kind, items: [], status: .failed(sharedFailure)))
                    }
                    return (idx, section)
                }
                let have = Set(out.map(\.0))
                for (idx, plan) in plans.enumerated() where !have.contains(idx) {
                    out.append((idx, HomeSection(
                        id: plan.id, title: plan.title, subtitle: plan.subtitle,
                        kind: .youTubeCarousel, items: [],
                        status: .failed(sharedFailure))))
                }
            }
            return out
        }
        let sections = results.sorted { $0.0 < $1.0 }.map(\.1)
        let failures = sections.compactMap { section -> HomeFetchFailure? in
            guard case .failed(let message) = section.status else { return nil }
            return HomeFetchFailure(
                layer: .baseline,
                code: .baselineUnavailable,
                message: message)
        }
        return .baseline(
            scope: input.scope,
            sections: sections,
            failures: failures)
    }

    func more(page: Int, input: HomeDiscoveryInput) async -> [HomeSection] {
        let seeds = input.topArtistNames + input.likedArtistNames
        let seed = seeds.isEmpty ? "music" : seeds[page % seeds.count]
        let queries = [
            "\(seed) mix",
            "new music \(currentYear)",
            "recommended \(seed)",
            "playlist \(seed) radio"
        ]
        let query = queries[page % queries.count]
        let plan = SectionPlan(
            id: "more-\(page)",
            title: tr("More for you", "更多推荐"),
            subtitle: tr("From YouTube Music", "来自 YouTube Music"),
            query: query)
        return [await runSection(plan: plan, input: input)]
    }

    // MARK: - Section planning

    /// 区段计划:稳定 id + 本地化标题 + 主题查询串。
    private struct SectionPlan: Sendable {
        let id: String
        let title: String
        let subtitle: String?
        let query: String
        var url: String? = nil
    }

    private func sectionPlans(for input: HomeDiscoveryInput) -> [SectionPlan] {
        var plans: [SectionPlan] = [
            SectionPlan(
                id: "new-releases",
                title: tr("New releases", "新发行"),
                subtitle: tr("From YouTube Music", "来自 YouTube Music"),
                query: "new music \(currentYear) official audio",
                url: YouTubeMusicCatalog.newReleases
            ),
            SectionPlan(
                id: "quick-picks",
                title: tr("Quick picks", "快速精选"),
                subtitle: tr("Play all", "全部播放"),
                query: input.topArtistNames.first.map { "\($0) popular songs mix" }
                    ?? "popular music mix",
                url: YouTubeMusicCatalog.moods
            ),
            seasonalPlan()
        ]

        if let recent = input.recentlyPlayedArtistNames.first {
            let seed = input.seedVideoIds.first
            plans.append(SectionPlan(
                id: "listen-again",
                title: tr("Listen again", "再听一次"),
                subtitle: tr("From YouTube Music", "来自 YouTube Music"),
                query: "\(recent) mix",
                url: seed.map { YouTubeMusicCatalog.mix(videoId: $0) }))
        } else if let seed = input.seedVideoIds.first {
            plans.append(SectionPlan(
                id: "listen-again",
                title: tr("Listen again", "再听一次"),
                subtitle: tr("From YouTube Music", "来自 YouTube Music"),
                query: "music mix",
                url: YouTubeMusicCatalog.mix(videoId: seed)))
        }

        if let artist = input.topArtistNames.first {
            let mixSeed = input.seedVideoIds.dropFirst().first ?? input.seedVideoIds.first
            plans.append(SectionPlan(
                id: "top-artist",
                title: tr("Mixed for you · \(artist)", "为你精选 · \(artist)"),
                subtitle: tr("From YouTube Music", "来自 YouTube Music"),
                query: "\(artist) mix radio",
                url: mixSeed.map { YouTubeMusicCatalog.mix(videoId: $0) }))
        }

        if let liked = input.likedArtistNames.first, liked != input.topArtistNames.first {
            plans.append(SectionPlan(
                id: "from-liked",
                title: tr("Because you like \(liked)", "因为你喜欢 \(liked)"),
                subtitle: tr("From YouTube Music", "来自 YouTube Music"),
                query: "\(liked) essentials playlist"))
        }

        plans.append(SectionPlan(
            id: "trending",
            title: tr("Charts", "排行榜"),
            subtitle: tr("From YouTube Music", "来自 YouTube Music"),
            query: "trending charts \(currentYear)",
            url: YouTubeMusicCatalog.charts))

        return plans
    }

    private func seasonalPlan(now: Date = .init()) -> SectionPlan {
        switch Calendar.current.component(.month, from: now) {
        case 6...8:
            SectionPlan(id: "seasonal", title: tr("That summer feeling", "夏日氛围"),
                        subtitle: tr("Soundtrack the season", "本季原声"),
                        query: "summer music playlist")
        case 9...11:
            SectionPlan(id: "seasonal", title: tr("Autumn atmosphere", "秋日氛围"),
                        subtitle: tr("Soundtrack the season", "本季原声"),
                        query: "autumn music playlist")
        case 12, 1, 2:
            SectionPlan(id: "seasonal", title: tr("Winter listening", "冬日聆听"),
                        subtitle: tr("Soundtrack the season", "本季原声"),
                        query: "winter music playlist")
        default:
            SectionPlan(id: "seasonal", title: tr("Spring refresh", "春日焕新"),
                        subtitle: tr("Soundtrack the season", "本季原声"),
                        query: "spring music playlist")
        }
    }

    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }

    // MARK: - Per-section execution

    private func runSection(plan: SectionPlan, input: HomeDiscoveryInput) async -> HomeSection {
        do {
            let loaded = try await loadEntries(plan)
            let trustedEntries = loaded.entries.filter {
                loaded.fromMusicCatalog || YouTubeMusicTrust.isTrustedHomeEntry($0)
            }
            guard !trustedEntries.isEmpty else {
                return HomeSection(
                    id: plan.id,
                    title: plan.title,
                    subtitle: plan.subtitle,
                    kind: .youTubeCarousel,
                    items: [],
                    status: .loaded)
            }
            let cards = trustedEntries.map(YouTubeDiscoveryCard.init(entry:))
            let ranked = lightlyRank(cards, input: input).prefix(displayLimit).map { $0 }
            return HomeSection(
                id: plan.id,
                title: plan.title,
                subtitle: plan.subtitle,
                kind: plan.id == "quick-picks" ? .quickPicks : .youTubeCarousel,
                items: ranked.map { .youTube($0) },
                status: .loaded)
        } catch is CancellationError {
            return HomeSection(
                id: plan.id, title: plan.title, subtitle: plan.subtitle,
                kind: .youTubeCarousel, items: [], status: .failed(nil))
        } catch {
            if Task.isCancelled {
                return HomeSection(
                    id: plan.id, title: plan.title, subtitle: plan.subtitle,
                    kind: .youTubeCarousel, items: [], status: .failed(nil))
            }
            let raw = error.localizedDescription
            let clipped = raw.count > 180 ? String(raw.prefix(180)) + "…" : raw
            return HomeSection(
                id: plan.id,
                title: plan.title,
                subtitle: plan.subtitle,
                kind: .youTubeCarousel,
                items: [],
                status: .failed(clipped.isEmpty ? nil : clipped))
        }
    }

    private func loadEntries(_ plan: SectionPlan) async throws -> (
        entries: [YTDlpBridge.YTDlpPlaylistEntry],
        fromMusicCatalog: Bool
    ) {
        if let url = plan.url, let fetch = fetchPlaylist {
            do {
                let fromCatalog = try await fetch(url)
                // Some public Music endpoints redirect guests to a generic
                // page that yt-dlp flattens into one unrelated video. A real
                // shelf needs enough entries to be credible; sparse output
                // falls through to the section-specific public search.
                let acceptsSingleMix = plan.id == "listen-again" || plan.id == "top-artist"
                let minimumShelfCount = acceptsSingleMix ? 1 : min(4, displayLimit)
                if fromCatalog.count >= minimumShelfCount {
                    return (fromCatalog, true)
                }
            } catch {
                // Fall through to ytsearch.
            }
        }
        return (try await search(plan.query, perSectionLimit), false)
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
