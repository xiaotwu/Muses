import Testing
import Foundation
import SwiftData
@testable import Muses

/// Phase 17 — Smart Listening History 验收:
/// - `ListeningEvent` @Model 可入库且 outcome/source 计算属性正确;
/// - `HistoryService` 订阅事件总线,按 Started/Completed/Skipped/Stopped 落库并分类;
/// - 功能开关闭合:关闭时不落库但保留事件边界;
/// - `PlaybackService` 端到端(用桩引擎,避开 headless 下 AVAudioPlayerNode 的
///   "player did not see an IO cycle" ObjC 异常):跳过→skipped、自然完成→completed;
/// - `HistoryQuery` 过滤与 `ListeningRecap` 汇总正确。
@Suite("Phase 17 History")
@MainActor
struct Phase17HistoryTests {

    private func makeContainer() throws -> ModelContainer {
        try makeModelContainer(inMemory: true)
    }

    private func snap(_ title: String, id: UUID = UUID(),
                      durationSec: Double = 200) -> TrackSnapshot {
        TrackSnapshot(id: id, title: title, artist: "Artist \(title)",
                      albumTitle: "Album \(title)", durationSeconds: durationSec,
                      youTubeId: "yt\(title)",
                      artworkUrl: nil,
                      sampleRate: 44100, bitDepth: 16, codec: "pcm", isLossless: false)
    }

    // MARK: - 模型

    @Test("ListeningEvent 持久化往返 + outcome/source 计算属性")
    func eventRoundTrip() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let ev = ListeningEvent(trackId: UUID(), trackTitle: "t", artist: "a",
                                albumTitle: "al", startedAt: Date(timeIntervalSince1970: 1000),
                                endedAt: Date(timeIntervalSince1970: 1100), listenedMs: 95000,
                                completionRatio: 0.95, outcome: .completed)
        ctx.insert(ev)
        try ctx.save()
        let fetched = try ctx.fetch(FetchDescriptor<ListeningEvent>()).first
        #expect(fetched?.trackTitle == "t")
        #expect(fetched?.outcome == .completed)
        #expect(fetched?.listenedMs == 95000)
        #expect(fetched?.completionRatio == 0.95)
        #expect(fetched?.endedAt != nil)
    }

    @Test("ListeningEvent 表已加入 schema(空查询成功)")
    func schemaIncludesListeningEvent() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        #expect(try ctx.fetch(FetchDescriptor<ListeningEvent>()).isEmpty)
    }

    // MARK: - HistoryService 事件落库

    @Test("trackStarted→trackCompleted 落库一条 completed 事件")
    func completedPersists() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let svc = HistoryService(modelContainer: container, eventBus: bus,
                                 enabledProvider: { true })
        let id = UUID()
        bus.post(.trackStarted(snap("A", id: id)))
        bus.post(.trackCompleted(snap("A", id: id), listenedMs: 200_000))
        let ctx = ModelContext(container)
        let events = try ctx.fetch(FetchDescriptor<ListeningEvent>())
        #expect(events.count == 1)
        #expect(events[0].outcome == .completed)
        #expect(events[0].trackId == id)
        #expect(events[0].listenedMs == 200_000)
        #expect(events[0].completionRatio == 1.0)  // 200000 / 200000ms
        _ = svc
    }

    @Test("trackSkipped 落库 skipped;trackStopped 落库 stopped")
    func skippedStoppedClassify() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let svc = HistoryService(modelContainer: container, eventBus: bus, enabledProvider: { true })
        let a = UUID(), b = UUID()
        bus.post(.trackStarted(snap("A", id: a)))
        bus.post(.trackSkipped(snap("A", id: a), listenedMs: 5_000))
        bus.post(.trackStarted(snap("B", id: b)))
        bus.post(.trackStopped(snap("B", id: b), listenedMs: 180_000))
        let ctx = ModelContext(container)
        let events = try ctx.fetch(FetchDescriptor<ListeningEvent>())
        #expect(events.count == 2)
        #expect(events.contains { $0.outcome == .skipped && $0.trackId == a && $0.listenedMs == 5_000 })
        #expect(events.contains { $0.outcome == .stopped && $0.trackId == b && $0.listenedMs == 180_000 })
        _ = svc
    }

    @Test("新 trackStarted 覆盖未终结事件 → 旧事件以 interrupted 兜底落库")
    func interruptedFallback() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let svc = HistoryService(modelContainer: container, eventBus: bus, enabledProvider: { true })
        bus.post(.trackStarted(snap("A")))
        // 不发终结事件,直接开始新曲目
        bus.post(.trackStarted(snap("B")))
        let ctx = ModelContext(container)
        let events = try ctx.fetch(FetchDescriptor<ListeningEvent>())
        #expect(events.count == 1)
        #expect(events[0].outcome == .interrupted)
        #expect(events[0].listenedMs == 0)
        _ = svc
    }

    @Test("功能关闭时不落库;开启后落库")
    func featureFlagGating() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        // 用引用类型开关,避免闭包对 `var` 局部捕获的语义歧义。
        let flag = HistoryFlag17()
        let svc = HistoryService(modelContainer: container, eventBus: bus,
                                 enabledProvider: { flag.on })
        let a = UUID(), b = UUID()
        bus.post(.trackStarted(snap("A", id: a)))
        bus.post(.trackCompleted(snap("A", id: a), listenedMs: 200_000))
        #expect((try ModelContext(container).fetch(FetchDescriptor<ListeningEvent>())).isEmpty)

        flag.on = true
        bus.post(.trackStarted(snap("B", id: b)))
        bus.post(.trackSkipped(snap("B", id: b), listenedMs: 3_000))
        #expect((try ModelContext(container).fetch(FetchDescriptor<ListeningEvent>())).count == 1)
        _ = svc
    }

    @Test("pause/resume/seek/queueChanged 不产生事件行")
    func nonFinalizingEventsNoRow() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let svc = HistoryService(modelContainer: container, eventBus: bus, enabledProvider: { true })
        let s = snap("A")
        bus.post(.trackStarted(s))
        bus.post(.trackPaused(s))
        bus.post(.trackResumed(s))
        bus.post(.trackSeeked(trackId: s.id, toMs: 10000))
        bus.post(.queueChanged)
        #expect((try ModelContext(container).fetch(FetchDescriptor<ListeningEvent>())).isEmpty)
        _ = svc
    }

    // MARK: - 端到端(PlaybackService → 事件总线 → HistoryService,桩引擎)

    @Test("播放→切下一首:HistoryService 记录 skipped")
    func endToEndSkipRecords() async throws {
        let container = try makeContainer()
        let library = LibraryService(modelContainer: container)
        let queue = QueueService()
        let engine = StubPlayerEngine17()
        let playback = PlaybackService(youtubeEngine: engine, queue: queue, library: library)
        let svc = HistoryService(modelContainer: container, eventBus: playback.eventBus,
                                 enabledProvider: { true })

        let a = snap("A", durationSec: 200)
        let b = snap("B", durationSec: 200)
        playback.playTrack(a, context: [a, b], from: .songs)
        try await Task.sleep(for: .milliseconds(120))   // 等 async load + trackStarted
        // 桩引擎不推进 position → listenedMs = 0 < 阈值 → skipped
        playback.next()
        try await Task.sleep(for: .milliseconds(120))

        let events = try ModelContext(container).fetch(FetchDescriptor<ListeningEvent>())
        #expect(events.contains { $0.outcome == .skipped && $0.trackTitle == "A" })
        _ = svc
    }

    @Test("引擎自然完成回调:HistoryService 记录 completed")
    func endToEndCompletionRecords() async throws {
        let container = try makeContainer()
        let library = LibraryService(modelContainer: container)
        let queue = QueueService()
        let engine = StubPlayerEngine17()
        let playback = PlaybackService(youtubeEngine: engine, queue: queue, library: library)
        let svc = HistoryService(modelContainer: container, eventBus: playback.eventBus,
                                 enabledProvider: { true })

        let a = snap("A", durationSec: 200)
        playback.playTrack(a, context: [a], from: .songs)
        try await Task.sleep(for: .milliseconds(120))
        // 模拟引擎自然完成:触发 onCompletion 回调(由 PlaybackService 接管为 completed 路径)。
        engine.fireCompletion()
        try await Task.sleep(for: .milliseconds(120))

        let events = try ModelContext(container).fetch(FetchDescriptor<ListeningEvent>())
        // completed 的 listenedMs = 整曲时长 = 200s = 200000ms
        #expect(events.contains { $0.outcome == .completed && $0.trackTitle == "A" && $0.listenedMs == 200_000 })
        _ = svc
    }

    // MARK: - 查询与汇总

    @Test("HistoryQuery filters by outcome and text")
    func queryFilters() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let svc = HistoryService(modelContainer: container, eventBus: bus, enabledProvider: { true })
        let solar = UUID(), lunar = UUID()
        bus.post(.trackStarted(snap("Solar", id: solar)))
        bus.post(.trackCompleted(snap("Solar", id: solar), listenedMs: 200_000))
        bus.post(.trackStarted(snap("Lunar", id: lunar)))
        bus.post(.trackSkipped(snap("Lunar", id: lunar), listenedMs: 4_000))

        #expect(svc.events(matching: HistoryQuery(outcome: .skipped)).count == 1)
        #expect(svc.events(matching: HistoryQuery(outcome: .completed)).count == 1)
        #expect(svc.events(matching: HistoryQuery(titleContains: "Lun")).count == 1)
        #expect(svc.events(matching: HistoryQuery(artistContains: "Solar")).count == 1)
        _ = svc
    }

    @Test("recap aggregates total time, counts, unique items, and top tracks")
    func recapAggregation() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let svc = HistoryService(modelContainer: container, eventBus: bus, enabledProvider: { true })
        let solar = UUID(), lunar = UUID()
        // 同一首 Solar 播完两次
        bus.post(.trackStarted(snap("Solar", id: solar)))
        bus.post(.trackCompleted(snap("Solar", id: solar), listenedMs: 200_000))
        bus.post(.trackStarted(snap("Solar", id: solar)))
        bus.post(.trackCompleted(snap("Solar", id: solar), listenedMs: 200_000))
        bus.post(.trackStarted(snap("Lunar", id: lunar)))
        bus.post(.trackSkipped(snap("Lunar", id: lunar), listenedMs: 4_000))

        let recap = svc.recap(range: .allTime)
        #expect(recap.eventCount == 3)
        #expect(recap.completedCount == 2)
        #expect(recap.skippedCount == 1)
        #expect(recap.uniqueTracks == 2)
        #expect(recap.totalListenedMs == 404_000)
        #expect(recap.topTracks.first?.title == "Solar")
        #expect(recap.topTracks.first?.plays == 2)
        #expect(recap.topArtists.first?.name == "Artist Solar")
        let heatmap = try svc.dashboard(range: .allTime).heatmap
        #expect(heatmap.rows.count == 7)
        #expect(heatmap.rows.flatMap(\.cells).count == 168)
        #expect(heatmap.totalMs == 404_000)
        _ = svc
    }

    @Test("dashboard keeps timeline inside the selected calendar range")
    func dashboardScopesRecentActivityToSelectedRange() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldStart = now.addingTimeInterval(-3 * 86_400)
        context.insert(ListeningEvent(
            trackId: UUID(), trackTitle: "Earlier", artist: "Artist Earlier",
            albumTitle: nil, startedAt: oldStart, endedAt: oldStart.addingTimeInterval(120),
            listenedMs: 120_000, completionRatio: 1, outcome: .completed
        ))
        try context.save()

        let service = HistoryService(modelContainer: container, eventBus: PlaybackEventBus(),
                                     enabledProvider: { true })
        let dashboard = try service.dashboard(range: .day, now: now)
        #expect(dashboard.totalEventCount == 1)
        #expect(dashboard.recap.eventCount == 0)
        #expect(dashboard.recent.isEmpty)
    }

    @Test("clearAll 清空全部事件并 bump revision")
    func clearAll() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let svc = HistoryService(modelContainer: container, eventBus: bus, enabledProvider: { true })
        bus.post(.trackStarted(snap("A")))
        bus.post(.trackCompleted(snap("A"), listenedMs: 100_000))
        #expect(svc.eventCount() == 1)
        let rev = svc.historyRevision
        svc.clearAll()
        #expect(svc.eventCount() == 0)
        #expect(svc.historyRevision > rev)
        _ = svc
    }
}

/// Phase 17 测试专用桩引擎:load/play 永不抛错,不触碰 AVAudioEngine
/// (避开 headless 下 "player did not see an IO cycle" 的 ObjC 异常)。
/// position 不自动推进,使跳过判定可预测(listenedMs = 0)。
@MainActor
private final class StubPlayerEngine17: PlayerEngine {
    let state = PlayerState()
    var onCompletion: (@MainActor () -> Void)?

    func load(_ track: TrackSnapshot) async throws {
        state.track = track
        state.duration = track.durationSeconds
        state.position = 0
        state.isPlaying = true
    }
    func prepare(_ track: TrackSnapshot) async {}
    @discardableResult
    func playPrepared() -> Bool { false }
    func play() { state.isPlaying = true }
    func pause() { state.isPlaying = false }
    func toggle() { state.isPlaying.toggle() }
    func seek(to time: Double) { state.position = time }
    func setVolume(_ v: Float) {}
    func setEQ(_ bands: [EQBand]) {}
    func installSpectrumTap(_ handler: @escaping (SpectrumFrame) -> Void) {}
    func removeSpectrumTap() {}

    /// 测试触发「自然完成」:调用由 PlaybackService 安装的 onCompletion。
    func fireCompletion() {
        state.position = state.duration
        state.isPlaying = false
        onCompletion?()
    }
}

/// Phase 17 测试专用桩 bridge(从不被调用,仅为满足 YouTubeStreamEngine 构造器签名)。
@MainActor
private final class StubYTDlpBridge17: YTDlpBridgeProtocol {
    func resolveStreamURL(videoId: String, quality: String, timeout: TimeInterval) async throws -> URL {
        URL(string: "https://example.invalid/\(videoId)")!
    }
    func fetchPlaylist(url: String, timeout: TimeInterval) async throws -> [YTDlpBridge.YTDlpPlaylistEntry] { [] }
    func searchYouTube(query: String, limit: Int, timeout: TimeInterval) async throws -> [YTDlpBridge.YTDlpPlaylistEntry] { [] }
    func version() async -> String? { "stub17" }
}

/// 引用类型开关:供 `featureFlagGating` 注入 `enabledProvider`,使开/关切换对闭包可见。
@MainActor
private final class HistoryFlag17 {
    var on: Bool = false
}
