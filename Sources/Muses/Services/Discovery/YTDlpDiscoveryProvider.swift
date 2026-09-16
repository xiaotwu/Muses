import Foundation

/// Public YouTube Music source reader. A failed catalog request stays failed;
/// keyword searches are never presented as official discovery or listening history.
@MainActor
final class YTDlpDiscoveryProvider: HomeDiscoveryProvider {

    private let fetchPlaylist: (String) async throws -> [YTDlpBridge.YTDlpPlaylistEntry]
    private let displayLimit: Int

    init(displayLimit: Int = 10,
         fetchPlaylist: @escaping (String) async throws -> [YTDlpBridge.YTDlpPlaylistEntry]) {
        self.displayLimit = displayLimit
        self.fetchPlaylist = fetchPlaylist
    }

    func fetch(for input: HomeDiscoveryInput) async -> HomeFetchResult {
        // Read only source-defined public catalog sections.
        let plans = sectionPlans(for: input)
        // The fixed plan bounds concurrent requests.
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
        // yt-dlp exposes no continuation for these browse endpoints.
        []
    }

    // MARK: - Section planning

    /// A source-defined public catalog endpoint.
    private struct SectionPlan: Sendable {
        let id: String
        let title: String
        let subtitle: String?
        var url: String? = nil
    }

    private func sectionPlans(for input: HomeDiscoveryInput) -> [SectionPlan] {
        [
            SectionPlan(id: "new-releases", title: tr("New releases", "新发行"),
                        subtitle: "YouTube Music", url: YouTubeMusicCatalog.newReleases),
            SectionPlan(id: "quick-picks", title: tr("Moods & genres", "心情与曲风", zhHant: "心情與曲風"),
                        subtitle: "YouTube Music", url: YouTubeMusicCatalog.moods)
        ]
    }

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
            let ranked = Array(cards.prefix(displayLimit))
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
        guard let url = plan.url,
              case .playlist? = YouTubeImportURL(url) else {
            // yt-dlp can flatten a Music browse redirect into unrelated videos.
            // These endpoints require a structured catalog provider; never label
            // generic extraction as official releases, moods, or charts.
            throw DiscoverySourceError.unavailable
        }
        let entries = try await fetchPlaylist(url)
        try Task.checkCancellation()
        return (entries, true)
    }

    private enum DiscoverySourceError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            tr("Official discovery is unavailable. Try again later.",
               "官方发现内容暂不可用，请稍后重试。", zhHant: "官方探索內容暫不可用，請稍後重試。")
        }
    }
}
