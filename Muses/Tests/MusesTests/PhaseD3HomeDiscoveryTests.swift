import Testing
import Foundation
@testable import Muses

/// Phase D3 — Home 动态发现纯逻辑测试。
///
/// 覆盖:`YTDlpDiscoveryProvider`(区段 plan / 独立失败 / 轻度排序)、
/// `HomeDiscoveryService`(cache-first / ffDiscovery-off no-op / loading 占位)、
/// `HomeFeedCache`(key 稳定 / SWR / invalidate)。
/// 不触网络/yt-dlp/SwiftData:provider 搜索入口与 service provider 均以桩注入。
@Suite("Phase D3 — Home Discovery")
@MainActor
struct PhaseD3HomeDiscoveryTests {

    // MARK: - 测试辅助

    private func entry(_ id: String, _ title: String, _ uploader: String?) -> YTDlpBridge.YTDlpPlaylistEntry {
        .init(id: id, title: title, uploader: uploader, duration: 200)
    }

    private func input(topArtists: [String] = [],
                       liked: [String] = [],
                       band: ListeningContext.TimeBand = .morning,
                       hour: Int = 9) -> HomeDiscoveryInput {
        HomeDiscoveryInput(
            topArtistNames: topArtists,
            recentlyPlayedArtistNames: [],
            likedArtistNames: liked,
            timeBand: band,
            hour: hour)
    }

    // MARK: - YTDlpDiscoveryProvider:区段 plan

    @Test("provider: topArtist 存在 → top-artist 区段;始终有 trending")
    func providerTopArtistAndTrending() async {
        let provider = YTDlpDiscoveryProvider(perSectionLimit: 6, displayLimit: 5) { _, _ in
            [entry("v1", "Song", "U")]
        }
        let sections = await provider.sections(for: input(topArtists: ["Ada"]))
        let ids = sections.map(\.id)
        #expect(ids.contains("top-artist"))
        #expect(ids.contains("trending"))
        #expect(ids.contains("time-of-day"))
    }

    @Test("provider: 无 topArtist → 无 top-artist 区段,但仍有 trending + time-of-day")
    func providerNoTopArtist() async {
        let provider = YTDlpDiscoveryProvider { _, _ in [] }
        let sections = await provider.sections(for: input(topArtists: []))
        let ids = sections.map(\.id)
        #expect(!ids.contains("top-artist"))
        #expect(ids.contains("trending"))
        #expect(ids.contains("time-of-day"))
    }

    @Test("provider: liked 艺术家不同于 topArtist → from-liked 区段")
    func providerFromLiked() async {
        let provider = YTDlpDiscoveryProvider { _, _ in [] }
        let sections = await provider.sections(for: input(topArtists: ["Ada"], liked: ["Bob"]))
        #expect(sections.map(\.id).contains("from-liked"))
    }

    @Test("provider: liked == topArtist → 不重复 from-liked 区段")
    func providerLikedEqualsTop() async {
        let provider = YTDlpDiscoveryProvider { _, _ in [] }
        let sections = await provider.sections(for: input(topArtists: ["Ada"], liked: ["Ada"]))
        #expect(!sections.map(\.id).contains("from-liked"))
    }

    @Test("provider: 区段标题由 input 派生(含艺术家名),非硬编码常量")
    func providerTitlesDerived() async {
        let provider = YTDlpDiscoveryProvider { _, _ in [] }
        let sections = await provider.sections(for: input(topArtists: ["Ada"]))
        let topTitle = sections.first { $0.id == "top-artist" }?.title
        #expect(topTitle?.contains("Ada") == true)
    }

    @Test("provider: timeBand 驱动时段区段标题")
    func providerTimeBandTitles() async {
        let provider = YTDlpDiscoveryProvider { _, _ in [] }
        let morning = await provider.sections(for: input(band: .morning, hour: 9))
        let late = await provider.sections(for: input(band: .lateNight, hour: 2))
        let mTitle = morning.first { $0.id == "time-of-day" }?.title
        let lTitle = late.first { $0.id == "time-of-day" }?.title
        #expect(mTitle != lTitle)
        #expect(mTitle?.isEmpty == false)
        #expect(lTitle?.isEmpty == false)
    }

    // MARK: - 独立失败(per-section failure)

    @Test("provider: 单 section 查询抛错 → 该 section .failed,其它 .loaded 不被毒化")
    func providerSectionIndependence() async {
        let provider = YTDlpDiscoveryProvider(perSectionLimit: 4, displayLimit: 4) { query, _ in
            // trending 查询模拟失败,其余成功。
            if query.contains("trending") { throw NSError(domain: "test", code: 1) }
            return [entry("v-\(query)", "Song", "U")]
        }
        let sections = await provider.sections(for: input(topArtists: ["Ada"]))
        let trending = sections.first { $0.id == "trending" }
        let top = sections.first { $0.id == "top-artist" }
        if case .failed = trending?.status { /* ok */ } else {
            Issue.record("trending 应为 .failed")
        }
        if case .loaded = top?.status { /* ok */ } else {
            Issue.record("top-artist 应保持 .loaded")
        }
        #expect(top?.items.isEmpty == false)
        #expect(trending?.items.isEmpty == true)
    }

    // MARK: - 轻度历史排序

    @Test("provider: uploader 命中 topArtist 的卡片前置,未命中保持原序")
    func providerLightRanking() async {
        let entries = [
            entry("a", "A", "Other"),
            entry("b", "B", "Ada"),
            entry("c", "C", "Someone"),
            entry("d", "D", "Ada"),
        ]
        let provider = YTDlpDiscoveryProvider(displayLimit: 10) { _, _ in entries }
        let sections = await provider.sections(for: input(topArtists: ["Ada"]))
        let top = sections.first { $0.id == "top-artist" }
        let ids = top?.items.compactMap { if case .youTube(let c) = $0 { c.id } else { nil } }
        // 命中 Ada 的两张前置(b, d),其余按原序(a, c)。
        #expect(ids == ["b", "d", "a", "c"])
    }

    @Test("provider: 无历史信号 → 不重排,保持原序")
    func providerNoRankingWhenNoSignals() async {
        let entries = [entry("a", "A", "X"), entry("b", "B", "Y")]
        let provider = YTDlpDiscoveryProvider(displayLimit: 10) { _, _ in entries }
        let sections = await provider.sections(for: input(topArtists: []))
        let top = sections.first { $0.id == "trending" }
        let ids = top?.items.compactMap { if case .youTube(let c) = $0 { c.id } else { nil } }
        #expect(ids == ["a", "b"])
    }

    // MARK: - HomeFeedCache

    @Test("HomeFeedCache: key 随 topArtists/liked 变化,不受 hour 抖动影响")
    func cacheKeyStability() {
        let i1 = input(topArtists: ["Ada"], liked: ["Bob"], band: .morning, hour: 9)
        let i2 = input(topArtists: ["Ada"], liked: ["Bob"], band: .morning, hour: 10)
        // 仅 hour 不同 → 同 key(band 一致)。
        #expect(HomeFeedCache.key(for: i1) == HomeFeedCache.key(for: i2))
        let i3 = input(topArtists: ["Ada"], liked: ["Bob"], band: .lateNight, hour: 2)
        #expect(HomeFeedCache.key(for: i1) != HomeFeedCache.key(for: i3))
    }

    @Test("HomeFeedCache: set/get 往返;isFresh 随窗口判定")
    func cacheSetGetFresh() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("muses-d3-test-\(UUID().uuidString)")
        let cache = HomeFeedCache(directory: dir, freshWindow: 60)
        let inp = input(topArtists: ["Ada"])
        let sections = [HomeSection(id: "trending", title: "T", kind: .youTubeCarousel,
                                    items: [.youTube(.init(id: "v", title: "S"))])]
        cache.set(sections, for: inp)
        let got = cache.get(for: inp)
        #expect(got != nil)
        #expect(got?.value.first?.id == "trending")
        #expect(cache.isFresh(got!) == true)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("HomeFeedCache: invalidate 后 get 返回 nil")
    func cacheInvalidate() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("muses-d3-test-\(UUID().uuidString)")
        let cache = HomeFeedCache(directory: dir, freshWindow: 60)
        let inp = input(topArtists: ["Ada"])
        cache.set([HomeSection(id: "x", title: "T", kind: .youTubeCarousel, items: [])], for: inp)
        cache.invalidate()
        #expect(cache.get(for: inp) == nil)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - HomeDiscoveryService

    /// 桩 provider:返回固定区段集合。
    private final class StubProvider: HomeDiscoveryProvider {
        var sectionsToReturn: [HomeSection]
        init(_ sections: [HomeSection]) { self.sectionsToReturn = sections }
        func sections(for input: HomeDiscoveryInput) async -> [HomeSection] { sectionsToReturn }
    }

    @Test("service: ffDiscovery 关 → load() no-op,sections 保持空")
    func serviceDisabledNoOp() async {
        let svc = HomeDiscoveryService(
            provider: StubProvider([HomeSection(id: "x", title: "T", kind: .youTubeCarousel, items: [])]),
            cache: HomeFeedCache(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("muses-d3-test-\(UUID().uuidString)")),
            library: makeLibrary(),
            enabledProvider: { false })
        svc.load()
        #expect(svc.sections.isEmpty)
        #expect(svc.isEnabled == false)
    }

    @Test("service: 缓存命中 → sections 立即填充;新鲜 → 不触发刷新")
    func serviceCacheFirstFresh() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("muses-d3-test-\(UUID().uuidString)")
        let cache = HomeFeedCache(directory: dir, freshWindow: 3600)
        let svc = HomeDiscoveryService(
            provider: StubProvider([HomeSection(id: "fresh", title: "Fresh", kind: .youTubeCarousel, items: [])]),
            cache: cache,
            library: makeLibrary(),
            enabledProvider: { true })
        let inp = svc.buildInput()
        // 预置新鲜缓存。
        cache.set([HomeSection(id: "cached", title: "Cached", kind: .youTubeCarousel, items: [])], for: inp)
        svc.load()
        // 立即应反映缓存(同步路径)。
        #expect(svc.sections.first?.id == "cached")
        #expect(svc.isRefreshing == false)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("service: 无缓存冷启 → loading 占位;刷新后替换为 provider 结果")
    func serviceColdLoadThenRefresh() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("muses-d3-test-\(UUID().uuidString)")
        let cache = HomeFeedCache(directory: dir, freshWindow: 3600)
        let provider = StubProvider([HomeSection(id: "loaded", title: "Loaded",
                                                 kind: .youTubeCarousel, items: [])])
        let svc = HomeDiscoveryService(
            provider: provider,
            cache: cache,
            library: makeLibrary(),
            enabledProvider: { true })
        svc.load()
        // 冷启:loading 占位(含 trending)。
        #expect(svc.sections.contains { $0.id == "trending" && $0.status == .loading })
        // 等待后台刷新完成(provider 立即返回)。
        for _ in 0..<100 {
            if !svc.isRefreshing { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(svc.sections.first?.id == "loaded")
        if case .loaded = svc.sections.first?.status { /* ok */ } else {
            Issue.record("刷新后应为 .loaded")
        }
        // 结果应已写入缓存。
        #expect(cache.get(for: svc.buildInput())?.value.first?.id == "loaded")
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("service: cancel 取消在途刷新,isRefreshing 归零")
    func serviceCancel() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("muses-d3-test-\(UUID().uuidString)")
        let provider = StubProvider([])
        let svc = HomeDiscoveryService(
            provider: provider,
            cache: HomeFeedCache(directory: dir, freshWindow: 3600),
            library: makeLibrary(),
            enabledProvider: { true })
        svc.load()
        svc.cancel()
        #expect(svc.isRefreshing == false)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - library 构造(测试用最小 in-memory ModelContainer)

    private func makeLibrary() -> LibraryService {
        let container = try! makeModelContainer(inMemory: true)
        let meta = MetadataService(artworkCache: .default)
        return LibraryService(modelContainer: container, metadata: meta)
    }
}