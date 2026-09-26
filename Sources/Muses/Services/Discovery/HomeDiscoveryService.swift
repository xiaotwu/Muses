import Foundation
import Observation

/// Home discovery service.
///
/// `@MainActor @Observable`. Exposes `sections: [HomeSection]` and `isEnabled`.
/// `load()` is cache-first: sections from the active mode's partition (possibly stale) render
/// immediately, then refresh in the background. One section failure never poisons the others.
///
/// With `ffDiscovery` off, `load()` is a no-op and `sections` stays empty; HomeView falls back to its existing behavior.
@MainActor
@Observable
final class HomeDiscoveryService {
    /// Current sections from the selected recommendation mode.
    private(set) var sections: [HomeSection] = []
    /// Whether discovery is refreshing in the background.
    private(set) var isRefreshing: Bool = false
    /// Account/input-scoped cache freshness shown by Home.
    private(set) var lastUpdatedAt: Date?
    private(set) var isShowingStale = false
    private(set) var lastRefreshError: String?
    private(set) var activeScope: HomeFeedScope = .guest
    private(set) var activeMode: HomeRecommendationMode = .muses
    private(set) var webCapability: HomeWebCapability = .notConfigured

    private let provider: HomeDiscoveryProvider
    private let cache: HomeFeedCache
    private let library: LibraryService
    private let enabledProvider: () -> Bool
    private let modeProvider: () -> HomeRecommendationMode
    private let accountChannelIDProvider: () -> String?
    private var refreshTask: Task<Void, Never>?
    /// Invalidates every refresh and continuation when Home leaves, changes mode,
    /// or changes account. A scope check alone is insufficient for guest-to-guest
    /// mode changes because both requests can share the same scope.
    private var operationID = UUID()
    private var morePage = 0
    private(set) var isLoadingMore = false
    private(set) var loadingSectionIDs: Set<String> = []
    private(set) var continuationErrors: [String: String] = [:]

    init(provider: HomeDiscoveryProvider,
         cache: HomeFeedCache = .default,
         library: LibraryService,
         enabledProvider: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: PrefKey.ffDiscovery) },
         modeProvider: @escaping () -> HomeRecommendationMode = {
             HomeRecommendationMode(
                rawValue: UserDefaults.standard.string(forKey: PrefKey.homeRecommendationMode) ?? ""
             ) ?? .muses
         },
         accountChannelIDProvider: @escaping () -> String? = { nil }) {
        self.provider = provider
        self.cache = cache
        self.library = library
        self.enabledProvider = enabledProvider
        self.modeProvider = modeProvider
        self.accountChannelIDProvider = accountChannelIDProvider
    }

    var isEnabled: Bool { enabledProvider() }
    var recommendationMode: HomeRecommendationMode { modeProvider() }

    // MARK: - Load

    /// Cache-first load of the selected mode's discovery sections.
    /// - Fill `sections` immediately from cache even when stale (stale-while-revalidate).
    /// - Fresh cache → skip the background spawn.
    /// - Otherwise refresh in the background: the provider yields per-section statuses that merge back into `sections`.
    func load() {
        guard isEnabled else { return }
        let input = buildInput()
        let mode = recommendationMode
        activeMode = mode
        activeScope = input.scope
        let baselineCache = cache.get(for: input, layer: .baseline, mode: mode)
        let webCache = provider.hasWebEnhancement
            ? cache.get(for: input, layer: .web, mode: mode)
            : nil
        let baselineIsFresh = baselineCache.map {
            cache.isFresh($0, layer: .baseline)
        } ?? false
        let webIsFresh = webCache.map {
            cache.isFresh($0, layer: .web)
        } ?? false

        if let baselineCache {
            let baselineReason = baselineIsFresh ? nil : "expired"
            let baselineSections = baselineCache.value.sections.map {
                $0.presentedFromCache(staleReason: baselineReason)
            }
            let webSections = webCache?.value.sections.map {
                $0.presentedFromCache(staleReason: webIsFresh ? nil : "expired")
            } ?? []
            sections = compose(web: webSections, baseline: baselineSections)
            lastUpdatedAt = [baselineCache.value.fetchedAt, webCache?.value.fetchedAt]
                .compactMap { $0 }.max()
            isShowingStale = !baselineIsFresh || (webCache != nil && !webIsFresh)

            if case .account(let channelID) = input.scope, webCache != nil {
                webCapability = .saved(
                    accountChannelID: channelID,
                    stale: !webIsFresh,
                    reason: webIsFresh ? nil : "expired")
            } else {
                webCapability = initialWebCapability(for: input.scope)
            }
            PerfTrace.event("home.discovery.cachedHit")
            let webRequirementSatisfied = !provider.hasWebEnhancement
                || input.scope == .guest
                || webIsFresh
            if baselineIsFresh && webRequirementSatisfied {
                PerfTrace.event("home.discovery.fresh")
                return
            }
        } else {
            sections = loadingPlaceholders(for: input)
            PerfTrace.event("home.discovery.cold")
            isShowingStale = false
            webCapability = initialWebCapability(for: input.scope)
        }
        refresh(input: input)
    }

    func loadMore() {
        guard isEnabled, !isLoadingMore, !isRefreshing, morePage < 12 else { return }
        morePage += 1
        let page = morePage
        let input = buildInput()
        let mode = recommendationMode
        let operation = operationID
        isLoadingMore = true
        Task { [weak self] in
            guard let self else { return }
            let extra = await self.provider.more(page: page, input: input)
            guard !Task.isCancelled,
                  operation == self.operationID,
                  mode == self.recommendationMode,
                  input.scope == self.buildInput().scope else {
                self.isLoadingMore = false
                return
            }
            self.sections.append(contentsOf: extra)
            if extra.isEmpty {
                self.lastRefreshError = tr("More Home recommendations are temporarily unavailable.",
                                           "暂时无法加载更多首页推荐。",
                                           zhHant: "暫時無法載入更多首頁推薦。")
            }
            self.isLoadingMore = false
        }
    }

    func hasContinuation(for sectionID: String) -> Bool {
        provider.hasContinuation(for: sectionID)
    }

    func loadMore(sectionID: String) {
        guard isEnabled,
              provider.hasContinuation(for: sectionID),
              loadingSectionIDs.insert(sectionID).inserted else { return }
        let input = buildInput()
        let mode = recommendationMode
        let operation = operationID
        Task { [weak self] in
            guard let self else { return }
            let items = await self.provider.more(sectionID: sectionID, input: input)
            guard !Task.isCancelled,
                  operation == self.operationID,
                  input.scope == self.buildInput().scope,
                  mode == self.recommendationMode else {
                self.loadingSectionIDs.remove(sectionID)
                return
            }
            self.appendContinuation(items, to: sectionID)
            if items.isEmpty {
                self.continuationErrors[sectionID] = tr(
                    "This section could not load more items. Try again.",
                    "此区段无法加载更多内容，请重试。",
                    zhHant: "此區段無法載入更多內容，請重試。")
            } else {
                self.continuationErrors.removeValue(forKey: sectionID)
            }
            self.loadingSectionIDs.remove(sectionID)
        }
    }

    /// Cancels the in-flight refresh (page switches cancel).
    func cancel() {
        operationID = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        isLoadingMore = false
        loadingSectionIDs.removeAll(keepingCapacity: false)
        continuationErrors.removeAll(keepingCapacity: false)
    }

    /// Called when OAuth identity changes. Visible account content is cleared
    /// immediately; the previous account's on-disk cache remains dormant and
    /// can only be reopened by that same channel scope.
    func accountScopeDidChange() {
        guard transitionToCurrentAccountScope() else { return }
        load()
    }

    /// Applies an explicit source change without deleting either source's
    /// saved snapshot. The target cache is read synchronously by `load()`.
    func recommendationModeDidChange() {
        cancel()
        sections = []
        lastUpdatedAt = nil
        isShowingStale = false
        lastRefreshError = nil
        continuationErrors.removeAll(keepingCapacity: false)
        webCapability = .notConfigured
        morePage = 0
        activeMode = recommendationMode
        load()
    }

    /// Clears the old account immediately but deliberately does not start the
    /// new scope until the Web helper cancellation has completed.
    func accountScopeWillChange() {
        _ = transitionToCurrentAccountScope()
    }

    func resumeAfterAccountScopeChange() {
        load()
    }

    /// Forces a full refresh (pull-to-refresh / after settings changes).
    /// Uses async input building (moves the full-table reduce off the main thread); `load()` keeps the synchronous `buildInput()`
    /// to preserve the synchronous cache-hit display contract.
    func reload() {
        guard isEnabled else { return }
        refreshTask?.cancel()
        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let input = await self.buildInputAsync()
            self.refresh(input: input)
        }
    }

    /// Applies an opt-in/opt-out change without allowing a disabled Web layer
    /// (or its saved partition) to remain visible in the current feed.
    func webConfigurationDidChange() {
        cancel()
        sections.removeAll {
            $0.source == .signedInWeb || $0.cachedOrigin == .signedInWeb
        }
        webCapability = initialWebCapability(for: buildInput().scope)
        reload()
    }

    /// Deletes only the active OAuth account's normalized Web partition.
    /// Baseline discovery and every other account partition remain untouched.
    func clearSavedWebHomeForCurrentAccount() {
        let input = buildInput()
        guard case .account = input.scope else { return }
        cache.invalidate(scope: input.scope, layer: .web, mode: .youtubeMusic)
        sections.removeAll {
            $0.source == .signedInWeb || $0.cachedOrigin == .signedInWeb
        }
        webCapability = initialWebCapability(for: input.scope)
        lastRefreshError = nil
        reload()
    }

    /// Adds a normalized, in-memory continuation page to one live Web shelf.
    /// Continuation pages are not written to the durable cache because the
    /// associated token chain is intentionally process-local.
    func appendWebContinuation(_ items: [DiscoveryItem], to sectionID: String) {
        appendContinuation(items, to: sectionID)
    }

    private func appendContinuation(_ items: [DiscoveryItem], to sectionID: String) {
        guard let index = sections.firstIndex(where: { $0.id == sectionID }) else { return }
        let section = sections[index]
        var seen = Set(section.items.compactMap(\.homeMediaIdentity))
        let extra = items.filter { item in
            guard let identity = item.homeMediaIdentity else { return false }
            return seen.insert(identity).inserted
        }
        guard !extra.isEmpty else { return }
        sections[index] = replacingItems(in: section, with: section.items + extra)
    }

    // MARK: - Internals

    @discardableResult
    private func transitionToCurrentAccountScope() -> Bool {
        let newScope = buildInput().scope
        guard newScope != activeScope else { return false }
        cancel()
        activeScope = newScope
        sections = []
        webCapability = initialWebCapability(for: newScope)
        lastUpdatedAt = nil
        isShowingStale = false
        lastRefreshError = nil
        continuationErrors.removeAll(keepingCapacity: false)
        morePage = 0
        return true
    }

    private func refresh(input: HomeDiscoveryInput) {
        refreshTask?.cancel()
        isRefreshing = true
        let mode = recommendationMode
        let operation = operationID
        refreshTask = Task { [weak self] in
            guard let self else { return }
            // Home never asks YouTube Data API for personalization signals.
            // YouTube Music mode personalizes only through the isolated browser session.
            let result = await self.provider.fetch(for: input)
            guard !Task.isCancelled,
                  operation == self.operationID,
                  input.scope == self.buildInput().scope,
                  mode == self.recommendationMode else { return }
            let cachedBaseline = self.cache.get(for: input, layer: .baseline, mode: mode)
            let previousBaselineSections = cachedBaseline?.value.sections
                ?? self.sections.filter {
                    $0.source != .signedInWeb && $0.cachedOrigin != .signedInWeb
                }
            let previous = Dictionary(
                uniqueKeysWithValues: previousBaselineSections.map { ($0.id, $0) })
            let baselineFailure = result.failures.first { $0.layer == .baseline }
            var firstBaselineFailure: String?
            var mergedBaseline = result.baselineSnapshot.sections.map { section -> HomeSection in
                guard case .failed(let message) = section.status else { return section }
                firstBaselineFailure = firstBaselineFailure ?? message
                if let cached = previous[section.id], !cached.items.isEmpty {
                    return HomeSection(id: cached.id, title: cached.title,
                                       subtitle: cached.subtitle, kind: cached.kind,
                                       items: cached.items, status: .loaded,
                                       source: cached.source,
                                       cachedOrigin: cached.cachedOrigin,
                                       accountChannelID: cached.accountChannelID,
                                       schemaVersion: cached.schemaVersion,
                                       fetchedAt: cached.fetchedAt,
                                       expiresAt: cached.expiresAt,
                                       staleReason: message ?? cached.staleReason)
                }
                return section
            }

            // An anonymous request can fail before any shelves are available.
            // Preserve only this scope/mode/locale's cache; an empty successful
            // response must still replace old data rather than masquerade as stale.
            if mergedBaseline.isEmpty, let baselineFailure {
                let reason = baselineFailure.message ?? baselineFailure.code.rawValue
                mergedBaseline = previousBaselineSections.filter { !$0.items.isEmpty }
                    .map { $0.presentedFromCache(staleReason: reason) }
                if mergedBaseline.isEmpty {
                    mergedBaseline = [HomeSection(
                        id: "home:baseline-failure", title: "YouTube Music",
                        kind: .youTubeCarousel, items: [],
                        status: .failed(reason), source: .publicDiscovery)]
                }
            }

            if result.cacheDirectives.storeBaseline {
                _ = self.cache.set(result.baselineSnapshot, for: input, layer: .baseline, mode: mode)
            }

            let webFailure = result.failures.first { $0.layer == .web }
            let webSections: [HomeSection]
            if let webSnapshot = result.webSnapshot {
                if result.cacheDirectives.storeWeb {
                    _ = self.cache.set(webSnapshot, for: input, layer: .web, mode: mode)
                }
                webSections = webSnapshot.sections
                self.webCapability = result.webCapability
            } else {
                let savedWeb = self.cache.get(for: input, layer: .web, mode: mode)
                let savedReason = webFailure?.message
                    ?? result.failures.first(where: { $0.layer == .web })?.code.rawValue
                webSections = savedWeb?.value.sections.map {
                    $0.presentedFromCache(staleReason: savedReason)
                } ?? []
                if case .account(let channelID) = input.scope, savedWeb != nil {
                    PerfTrace.event("home.web.stale")
                    self.webCapability = .saved(
                        accountChannelID: channelID,
                        stale: true,
                        reason: savedReason)
                } else {
                    self.webCapability = result.webCapability
                }
            }

            self.sections = self.compose(web: webSections, baseline: mergedBaseline)
            self.lastRefreshError = baselineFailure?.message
                ?? firstBaselineFailure
                ?? webFailure?.message
            self.isShowingStale = webSections.contains { $0.source == .cached }
                || mergedBaseline.contains { $0.source == .cached || $0.staleReason != nil }
            self.lastUpdatedAt = [
                result.cacheDirectives.storeBaseline
                    ? result.baselineSnapshot.fetchedAt : cachedBaseline?.value.fetchedAt,
                result.webSnapshot?.fetchedAt,
                self.cache.get(for: input, layer: .web, mode: mode)?.value.fetchedAt
            ].compactMap { $0 }.max()
            self.isRefreshing = false
            PerfTrace.event("home.discovery.refreshed")
        }
    }

    private func compose(web: [HomeSection], baseline: [HomeSection]) -> [HomeSection] {
        let webIDs = Set(web.map(\.id))
        let webMediaIDs = Set(web.flatMap(\.items).compactMap(\.homeMediaIdentity))
        let remainingBaseline = baseline.compactMap { section -> HomeSection? in
            guard !webIDs.contains(section.id) else { return nil }
            let filtered = section.items.filter { item in
                guard let identity = item.homeMediaIdentity else { return true }
                return !webMediaIDs.contains(identity)
            }
            if !section.items.isEmpty, filtered.isEmpty { return nil }
            return replacingItems(in: section, with: filtered)
        }
        return web + remainingBaseline
    }

    private func replacingItems(
        in section: HomeSection,
        with items: [DiscoveryItem]
    ) -> HomeSection {
        HomeSection(
            id: section.id,
            title: section.title,
            subtitle: section.subtitle,
            kind: section.kind,
            items: items,
            status: section.status,
            source: section.source,
            cachedOrigin: section.cachedOrigin,
            accountChannelID: section.accountChannelID,
            schemaVersion: section.schemaVersion,
            fetchedAt: section.fetchedAt,
            expiresAt: section.expiresAt,
            staleReason: section.staleReason)
    }

    private func initialWebCapability(for scope: HomeFeedScope) -> HomeWebCapability {
        guard provider.hasWebEnhancement else { return .notConfigured }
        if scope == .guest { return .signedOut }
        return .unavailable(reason: nil)
    }

    /// Loading placeholders: prefill with section titles derived from the input (titles come from provider logic, never hardcoded in views).
    private func loadingPlaceholders(for input: HomeDiscoveryInput) -> [HomeSection] {
        if recommendationMode == .muses {
            return [
                HomeSection(id: "muses:on-repeat", title: tr("On Repeat", "循环热播"),
                            kind: .youTubeCarousel, items: [], status: .loading,
                            source: .localLibrary),
                HomeSection(id: "muses:rediscover", title: tr("Rediscover", "重新发现"),
                            kind: .youTubeCarousel, items: [], status: .loading,
                            source: .localLibrary)
            ]
        }
        // Reuse the provider's plan naming? Its plans are private. Derive equivalent titles from the input here,
        // keeping them consistent with the provider (title generation lives in the provider; this is a placeholder only).
        var placeholders: [HomeSection] = []
        if let recent = input.recentlyPlayedArtistNames.first {
            placeholders.append(HomeSection(
                id: "listen-again",
                title: tr("Listen again", "再听一次"),
                subtitle: recent,
                kind: .youTubeCarousel, items: [], status: .loading))
        }
        if let artist = input.topArtistNames.first {
            placeholders.append(HomeSection(
                id: "top-artist",
                title: tr("Mixed for you · \(artist)", "为你精选 · \(artist)", zhHant: "為你精選 · \(artist)"),
                subtitle: tr("From YouTube Music", "来自 YouTube Music"),
                kind: .youTubeCarousel, items: [], status: .loading))
        }
        placeholders.append(HomeSection(
            id: "quick-picks",
            title: tr("Quick picks", "快速精选"),
            subtitle: nil,
            kind: .youTubeCarousel, items: [], status: .loading))
        placeholders.append(seasonalPlaceholder())
        placeholders.append(HomeSection(
            id: "new-releases",
            title: tr("New releases", "新发行"),
            subtitle: nil,
            kind: .youTubeCarousel, items: [], status: .loading))
        if let liked = input.likedArtistNames.first, liked != input.topArtistNames.first {
            placeholders.append(HomeSection(
                id: "from-liked",
                title: tr("Because you like \(liked)", "因为你喜欢 \(liked)", zhHant: "因為你喜歡 \(liked)"),
                subtitle: tr("From YouTube Music", "来自 YouTube Music"),
                kind: .youTubeCarousel, items: [], status: .loading))
        }
        placeholders.append(HomeSection(
            id: "trending",
            title: tr("Charts", "排行榜"),
            subtitle: tr("From YouTube Music", "来自 YouTube Music"),
            kind: .youTubeCarousel, items: [], status: .loading))
        return placeholders
    }

    private func seasonalPlaceholder(now: Date = .init()) -> HomeSection {
        let title: String
        switch Calendar.current.component(.month, from: now) {
        case 6...8: title = tr("That summer feeling", "夏日氛围")
        case 9...11: title = tr("Autumn atmosphere", "秋日氛围")
        case 12, 1, 2: title = tr("Winter listening", "冬日聆听")
        default: title = tr("Spring refresh", "春日焕新")
        }
        return HomeSection(id: "seasonal", title: title,
                           subtitle: tr("Soundtrack the season", "本季原声"),
                           kind: .youTubeCarousel, items: [], status: .loading)
    }

    // MARK: - Input building

    /// Derives `HomeDiscoveryInput` from library + history (light history signals).
    func buildInput() -> HomeDiscoveryInput {
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        let band: ListeningContext.TimeBand = {
            switch hour {
            case 5..<12:  return .morning
            case 12..<18: return .afternoon
            case 18..<22: return .evening
            default:       return .lateNight
            }
        }()
        let topArtists = topArtistNames(limit: 5)
        let recentArtists = recentlyPlayedArtistNames(limit: 5)
        let likedArtists = likedArtistNames(limit: 5)
        return HomeDiscoveryInput(
            topArtistNames: topArtists,
            recentlyPlayedArtistNames: recentArtists,
            likedArtistNames: likedArtists,
            timeBand: band,
            hour: hour,
            seedVideoIds: seedVideoIds(),
            scope: HomeFeedScope(accountChannelID: accountChannelIDProvider()))
    }

    private func topArtistNames(limit: Int) -> [String] {
        // Reuses the library playCount aggregation (consistent with RecommendationService).
        let counts = library.allTracks().reduce(into: [String: Int]()) { acc, t in
            guard t.playCount > 0 else { return }
            acc[t.artist, default: 0] += t.playCount
        }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    private func recentlyPlayedArtistNames(limit: Int) -> [String] {
        library.recentlyPlayedTracks(limit: 50)
            .map(\.artist)
            .deduplicated(limit: limit)
    }

    private func likedArtistNames(limit: Int) -> [String] {
        library.likedTracks().map(\.artist).deduplicated(limit: limit)
    }

    private func seedVideoIds(limit: Int = 4) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in library.recentlyPlayedTracks(limit: 20).compactMap(\.youTubeId) {
            if seen.insert(id).inserted { out.append(id) }
            if out.count >= limit { break }
        }
        return out
    }

    /// Async input building: aggregates discovery signals on a detached task (single fetch derivation),
    /// moving the full-table reduce off the main thread. Used by `reload()`; `load()` keeps the synchronous `buildInput()`
    /// to preserve the synchronous cache-hit display contract.
    private func buildInputAsync() async -> HomeDiscoveryInput {
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        let band: ListeningContext.TimeBand = {
            switch hour {
            case 5..<12:  return .morning
            case 12..<18: return .afternoon
            case 18..<22: return .evening
            default:       return .lateNight
            }
        }()
        let signals = await library.discoverySignalsAsync(limit: 5)
        return HomeDiscoveryInput(
            topArtistNames: signals.topArtistNames,
            recentlyPlayedArtistNames: signals.recentlyPlayedArtistNames,
            likedArtistNames: signals.likedArtistNames,
            timeBand: band,
            hour: hour,
            seedVideoIds: seedVideoIds(),
            scope: HomeFeedScope(accountChannelID: accountChannelIDProvider()))
    }
}

/// Deduplicates, preserves order, and truncates.
private extension Array where Element == String {
    func deduplicated(limit: Int) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for v in self {
            let key = v.lowercased()
            if seen.insert(key).inserted { out.append(v) }
            if out.count >= limit { break }
        }
        return out
    }
}
