import Foundation

/// Default Home discovery provider built on yt-dlp `ytsearch`.
///
/// Architecture (user-confirmed): hybrid remote discovery — the outside YouTube music world is the primary source,
/// with listening history used only as a light ranking signal. The provider derives several themed
/// `ytsearch` queries from `HomeDiscoveryInput`, one section each; a failing section returns `.failed` without poisoning the rest.
///
/// Section titles are generated here (never hardcoded in views). Light history ranking: results are stably reordered by how much
/// each uploader overlaps the user's top/recent artist names.
///
/// The search entry point is injected as a closure for easy test stubbing and to decouple from the @MainActor `YTDlpBridge`.
@MainActor
final class YTDlpDiscoveryProvider: HomeDiscoveryProvider {

    /// yt-dlp search entry point. Defaults to bridging `YouTubeSearchService.search`/`YTDlpBridge.searchYouTube`.
    /// A thrown error marks that section `.failed`.
    private let search: (String, Int) async throws -> [YTDlpBridge.YTDlpPlaylistEntry]
    private let fetchPlaylist: ((String) async throws -> [YTDlpBridge.YTDlpPlaylistEntry])?
    /// Per-section result cap.
    private let perSectionLimit: Int
    /// Trims results to the display limit.
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
        // 1. Derive the themed query plan from the input (titles + query strings). Titles are generated here, never hardcoded in views.
        let plans = sectionPlans(for: input)
        // 2. Each section fetches independently; the TaskGroup concurrency is naturally bounded (fixed plan size ≤ 5).
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

    /// Section plan: stable id + localized title + topical query string.
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

    /// Light history ranking: cards whose uploader matches the user's top/recent artist names move stably to the front.
    /// Non-matching cards keep their relative order (stable).
    private func lightlyRank(_ cards: [YouTubeDiscoveryCard],
                              input: HomeDiscoveryInput) -> [YouTubeDiscoveryCard] {
        let signals = Set((input.topArtistNames + input.recentlyPlayedArtistNames)
            .map { $0.lowercased() })
        guard !signals.isEmpty else { return cards }
        return cards.stableSort { card in
            // Match scores 1, miss scores 0; the stable sort preserves the original order within equal scores.
            if let up = card.uploader?.lowercased(), signals.contains(up) { return 1 }
            return 0
        }
    }
}

/// Stable sort: descending by `score`, preserving original order for ties.
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
