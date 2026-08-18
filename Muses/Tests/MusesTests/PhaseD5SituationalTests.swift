import Testing
import Foundation
import SwiftData
@testable import Muses

/// Phase D5 — 情境化 New 推荐纯逻辑测试。
///
/// 覆盖:`SituationalRecommendationService.compute()` 在不同上下文(morning / lateNight /
/// 前台应用 / focus)下产出不同区段;local + YouTube 混排;rediscover 过滤;
/// 确定性;ffSituationalNew 关 → 返回空。打分确定可测。
/// 不触网络/yt-dlp:仅用资料库本地曲目 + source=.youtube 曲目。上下文/focus 经闭包注入。
@Suite("Phase D5 — Situational New")
@MainActor
struct PhaseD5SituationalTests {

    private func makeContainer() throws -> ModelContainer {
        try makeModelContainer(inMemory: true)
    }

    @discardableResult
    private func seedTracks(_ ctx: ModelContext,
                            local: [(title: String, artist: String, plays: Int, liked: Bool, lastPlayed: Date?)] = [],
                            youTube: [(title: String, artist: String, plays: Int, lastPlayed: Date?)] = []) -> [UUID] {
        var ids: [UUID] = []
        for s in local {
            let t = Track(source: .local, title: s.title, artist: s.artist, durationMs: 200_000)
            t.playCount = s.plays
            t.liked = s.liked
            t.lastPlayedAt = s.lastPlayed
            ctx.insert(t); ids.append(t.id)
        }
        for s in youTube {
            let t = Track(source: .youtube, title: s.title, artist: s.artist, durationMs: 200_000)
            t.playCount = s.plays
            t.lastPlayedAt = s.lastPlayed
            ctx.insert(t); ids.append(t.id)
        }
        try? ctx.save()
        return ids
    }

    private func library(for container: ModelContainer) -> LibraryService {
        LibraryService(modelContainer: container,
                       metadata: MetadataService(artworkCache: .default))
    }

    private func makeService(container: ModelContainer,
                             context: ListeningContext? = nil,
                             focusActive: Bool = false,
                             focusSessionId: UUID? = nil,
                             enabled: Bool = true) -> SituationalRecommendationService {
        SituationalRecommendationService(
            library: library(for: container),
            historyService: nil,
            modelContainer: container,
            enabledProvider: { enabled },
            contextProvider: { context },
            focusStateProvider: { (focusActive, focusSessionId) })
    }

    private func context(hour: Int, app: String? = nil, headphones: Bool? = nil) -> ListeningContext {
        ListeningContext(hour: hour, dayOfWeek: 3, isWeekend: false,
                         frontmostAppBundleId: app, outputDeviceName: nil,
                         isHeadphones: headphones)
    }

    // MARK: - 禁用路径

    @Test("ffSituationalNew 关 → compute() 返回空")
    func disabledReturnsEmpty() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        seedTracks(ctx, local: [("A", "Ada", 5, false, nil)])
        let svc = makeService(container: container, enabled: false)
        let sections = await svc.compute()
        #expect(sections.isEmpty)
        #expect(svc.isEnabled == false)
    }

    // MARK: - 时段区段

    @Test("无上下文 → 无 time-band 区段,但有资料库播放曲目 → recently-obsessed")
    func noContextNoTimeBand() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        seedTracks(ctx, local: [("M", "Ada", 3, false, Date())])
        let svc = makeService(container: container, context: nil)
        let sections = await svc.compute()
        #expect(!sections.contains { $0.id == "time-band" })
        #expect(sections.contains { $0.id == "recently-obsessed" })
    }

    @Test("morning 上下文 → time-band 区段存在且有曲目")
    func morningTimeBandSection() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        seedTracks(ctx, local: [("M", "Ada", 3, false, Date())])
        let svc = makeService(container: container, context: context(hour: 9))
        let sections = await svc.compute()
        let band = sections.first { $0.id == "time-band" }
        #expect(band != nil)
        #expect(band?.items.isEmpty == false)
    }

    @Test("lateNight 上下文 → time-band 标题为深夜")
    func lateNightTitle() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        seedTracks(ctx, local: [("N", "Ada", 3, false, Date())])
        let svc = makeService(container: container, context: context(hour: 2))
        let sections = await svc.compute()
        let band = sections.first { $0.id == "time-band" }
        #expect(band?.title.contains("Late") == true || band?.title.contains("深夜") == true)
    }

    @Test("morning 与 lateNight 的 time-band 标题不同")
    func morningVsLateNightTitles() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        seedTracks(ctx, local: [("X", "Ada", 3, false, Date())])
        let svcM = makeService(container: container, context: context(hour: 9))
        let svcL = makeService(container: container, context: context(hour: 2))
        let mBand = await svcM.compute().first { $0.id == "time-band" }
        let lBand = await svcL.compute().first { $0.id == "time-band" }
        #expect(mBand?.title != lBand?.title)
    }

    // MARK: - 前台应用区段

    @Test("上下文含前台应用 → app-rotation 区段,标题含应用名")
    func appRotationSection() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        seedTracks(ctx, local: [("A", "Ada", 3, false, Date())])
        let svc = makeService(container: container,
                              context: context(hour: 9, app: "com.apple.Xcode"))
        let sections = await svc.compute()
        let app = sections.first { $0.id == "app-rotation" }
        #expect(app != nil)
        #expect(app?.title.contains("Xcode") == true)
    }

    @Test("无前台应用 → 无 app-rotation 区段")
    func noAppNoRotation() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        seedTracks(ctx, local: [("A", "Ada", 3, false, Date())])
        let svc = makeService(container: container, context: context(hour: 9, app: nil))
        let sections = await svc.compute()
        #expect(!sections.contains { $0.id == "app-rotation" })
    }

    // MARK: - Focus 路径

    @Test("focus 激活 → 仅 focus 区段,无 time-band/recently-obsessed")
    func focusOnlySections() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        seedTracks(ctx, local: [("F", "Ada", 3, false, Date())])
        let svc = makeService(container: container,
                              context: context(hour: 9),
                              focusActive: true, focusSessionId: UUID())
        let sections = await svc.compute()
        let ids = Set(sections.map(\.id))
        #expect(!ids.contains("time-band"))
        #expect(!ids.contains("recently-obsessed"))
        #expect(ids.contains("focus-continue") || ids.contains("focus-low-distraction"))
    }

    // MARK: - local + YouTube 混排

    @Test("from-youtube 区段存在(资料库含 YouTube 来源曲目)")
    func youTubeSectionPresent() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        seedTracks(ctx,
                   local: [("L", "Ada", 2, false, Date())],
                   youTube: [("Y", "Bob", 2, Date())])
        let svc = makeService(container: container)
        let sections = await svc.compute()
        #expect(sections.contains { $0.id == "from-youtube" })
    }

    @Test("recently-obsessed 跨来源混排(本地 + YouTube 同时出现)")
    func mixedLocalAndYouTube() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        seedTracks(ctx,
                   local: [("L", "Ada", 5, true, Date())],
                   youTube: [("Y", "Bob", 5, Date())])
        let svc = makeService(container: container)
        let sections = await svc.compute()
        let obsessed = sections.first { $0.id == "recently-obsessed" }
        #expect(obsessed != nil)
        let titles = Set(obsessed?.items.map(\.title) ?? [])
        #expect(titles.contains("L") && titles.contains("Y"))
    }

    // MARK: - 确定性

    @Test("同输入两次 compute → 相同区段 id 顺序与曲目")
    func deterministic() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        seedTracks(ctx, local: [("A", "Ada", 3, true, Date()),
                                ("B", "Bob", 2, false, Date())])
        let svc = makeService(container: container)
        let s1 = await svc.compute()
        let s2 = await svc.compute()
        #expect(s1.map(\.id) == s2.map(\.id))
        #expect(s1.first?.items.map(\.id) == s2.first?.items.map(\.id))
    }

    // MARK: - Rediscover

    @Test("Rediscover 仅含收藏且 14 天未播曲目")
    func rediscoverFilter() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let recent = Date()
        let stale = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        seedTracks(ctx, local: [
            ("RecentLiked", "Ada", 1, true, recent),
            ("StaleLiked", "Bob", 1, true, stale),
            ("StaleNotLiked", "Cara", 1, false, stale),
        ])
        let svc = makeService(container: container)
        let sections = await svc.compute()
        let rediscover = sections.first { $0.id == "rediscover" }
        #expect(rediscover != nil)
        let titles = Set(rediscover?.items.map(\.title) ?? [])
        #expect(titles.contains("StaleLiked"))
        #expect(!titles.contains("RecentLiked"))
        #expect(!titles.contains("StaleNotLiked"))
    }

    // MARK: - 打分:播放数影响排序

    @Test("recently-obsessed 按播放数倒序(高播放前置)")
    func rankingByPlays() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        seedTracks(ctx, local: [
            ("Low", "Ada", 1, false, Date()),
            ("High", "Bob", 10, false, Date()),
            ("Mid", "Cara", 5, false, Date()),
        ])
        let svc = makeService(container: container)
        let sections = await svc.compute()
        let obsessed = sections.first { $0.id == "recently-obsessed" }
        let titles = obsessed?.items.map(\.title)
        #expect(titles?.first == "High")
    }
}