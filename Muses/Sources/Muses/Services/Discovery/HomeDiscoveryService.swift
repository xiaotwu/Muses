import Foundation
import Observation

/// Home 发现服务(Phase D3 / §3 / §16–18)。
///
/// `@MainActor @Observable`。对外暴露 `sections: [HomeSection]` 与 `isEnabled`。
/// `load()` **cache-first**:先以 `HomeFeedCache` 中的(可能 stale)sections 立即上屏,
/// 再在后台按 section 独立刷新(每 section 独立 status,单 section 失败不毒化其它)。
///
/// 当 `ffDiscovery` 关闭 → `load()` 为 no-op,`sections` 保持空;HomeView 回退到现有行为。
@MainActor
@Observable
final class HomeDiscoveryService {
    /// 当前发现区段(仅远程发现;本地区段由 HomeView 自行管理)。
    private(set) var sections: [HomeSection] = []
    /// 是否正在后台刷新远程发现。
    private(set) var isRefreshing: Bool = false

    private let provider: HomeDiscoveryProvider
    private let cache: HomeFeedCache
    private let library: LibraryService
    private let historyService: HistoryService?
    private let enabledProvider: () -> Bool
    private var refreshTask: Task<Void, Never>?

    init(provider: HomeDiscoveryProvider,
         cache: HomeFeedCache = .default,
         library: LibraryService,
         historyService: HistoryService? = nil,
         enabledProvider: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: PrefKey.ffDiscovery) }) {
        self.provider = provider
        self.cache = cache
        self.library = library
        self.historyService = historyService
        self.enabledProvider = enabledProvider
    }

    var isEnabled: Bool { enabledProvider() }

    // MARK: - Load

    /// Cache-first 加载远程发现区段。
    /// - 先以缓存(即使 stale)立即填充 `sections`(§16 stale-while-revalidate)。
    /// - 若缓存新鲜 → 跳过后台 spawn(§21)。
    /// - 否则后台刷新:provider 产出每 section 独立 status 的结果,合并回 `sections`。
    func load() {
        guard isEnabled else { return }
        let input = buildInput()
        // 1. 立即上屏缓存。
        if let cached = cache.get(for: input) {
            sections = cached.value
            PerfTrace.event("home.discovery.cachedHit")
            if cache.isFresh(cached) {
                PerfTrace.event("home.discovery.fresh")
                return
            }
        } else {
            // 无缓存:置各 planned section 为 loading 占位(标题先填,内容后补)。
            sections = loadingPlaceholders(for: input)
            PerfTrace.event("home.discovery.cold")
        }
        // 2. 后台刷新。
        refresh(input: input)
    }

    /// 取消在途刷新(页面切换取消,§23)。
    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    /// 强制重新刷新(下拉刷新 / 设置变更后)。
    func reload() {
        guard isEnabled else { return }
        let input = buildInput()
        refresh(input: input)
    }

    // MARK: - Internals

    private func refresh(input: HomeDiscoveryInput) {
        refreshTask?.cancel()
        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.provider.sections(for: input)
            guard !Task.isCancelled else { return }
            self.sections = result
            self.cache.set(result, for: input)
            self.isRefreshing = false
            PerfTrace.event("home.discovery.refreshed")
        }
    }

    /// loading 占位:用 input 派生的区段标题预填(标题来自 provider 逻辑,视图不硬编码)。
    private func loadingPlaceholders(for input: HomeDiscoveryInput) -> [HomeSection] {
        // 复用 provider 的 plan 命名?provider 内部 plan 是 private。此处用 input 派生
        // 等价标题,保持与 provider 一致(标题生成逻辑集中在 provider,这里仅占位)。
        var placeholders: [HomeSection] = []
        if let artist = input.topArtistNames.first {
            placeholders.append(HomeSection(
                id: "top-artist",
                title: tr("Top songs by \(artist)", "\(artist) 的热门歌曲"),
                subtitle: tr("From YouTube", "来自 YouTube"),
                kind: .youTubeCarousel, items: [], status: .loading))
        }
        placeholders.append(timeBandPlaceholder(for: input.timeBand))
        if let liked = input.likedArtistNames.first, liked != input.topArtistNames.first {
            placeholders.append(HomeSection(
                id: "from-liked",
                title: tr("Because you like \(liked)", "因为你喜欢 \(liked)"),
                subtitle: tr("From YouTube", "来自 YouTube"),
                kind: .youTubeCarousel, items: [], status: .loading))
        }
        placeholders.append(HomeSection(
            id: "trending",
            title: tr("Trending now", "正在流行"),
            subtitle: tr("From YouTube", "来自 YouTube"),
            kind: .youTubeCarousel, items: [], status: .loading))
        return placeholders
    }

    private func timeBandPlaceholder(for band: ListeningContext.TimeBand) -> HomeSection {
        let title: String, subtitle: String
        switch band {
        case .morning:   title = tr("Morning picks", "清晨精选"); subtitle = tr("Ease into the day", "从容开启一天")
        case .afternoon: title = tr("Afternoon rotation", "午后轮播"); subtitle = tr("Keep moving", "保持节奏")
        case .evening:   title = tr("Evening chill", "傍晚放松"); subtitle = tr("Wind down", "慢下来")
        case .lateNight: title = tr("Late-night picks", "深夜精选"); subtitle = tr("For the quiet hours", "献给安静的时刻")
        }
        return HomeSection(id: "time-of-day", title: title, subtitle: subtitle,
                           kind: .youTubeCarousel, items: [], status: .loading)
    }

    // MARK: - Input building

    /// 从 library + history 派生 `HomeDiscoveryInput`(轻度历史信号)。
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
            hour: hour)
    }

    private func topArtistNames(limit: Int) -> [String] {
        // 复用 library 的 playCount 聚合(与 RecommendationService 一致)。
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
}

/// 去重保序截断。
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