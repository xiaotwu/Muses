import Testing
import Foundation
import SwiftData
@testable import Muses

/// Phase 18 — Listening Sessions + Crash Recovery 验收(对应 Final Spec §10.5):
/// - `ListeningSession` @Model 入库 + status 计算属性;
/// - `SessionService` 订阅事件总线:`trackStarted` 开启/继续 active 会话 + checkpoint 崩溃恢复槽,
///   `trackSeeked` 更新位置,`trackCompleted`(队列耗尽)结束会话;
/// - 功能开关闭合:`ffSessions` 关时不落库、不弹恢复;
/// - 启动恢复:`checkForRestorableSession` 暴露 `pendingRestore`;陈旧(>2h)自动结束;
///   `continuePendingSession` 调 `playback.resumeCurrent` seek 到恢复位;
///   `discardPendingSession` 结束会话 + 清空崩溃恢复槽;绝不静默替换队列;
/// - 用桩引擎(RecordingEngine),避开 headless 下 AVAudioPlayerNode 的 IO-cycle 异常。
@Suite("Phase 18 Sessions")
@MainActor
struct Phase18SessionTests {

    private func makeContainer() throws -> ModelContainer {
        try makeModelContainer(inMemory: true)
    }

    private func snap(_ title: String, id: UUID = UUID(),
                      durationSec: Double = 200) -> TrackSnapshot {
        TrackSnapshot(id: id, title: title, artist: "Artist \(title)",
                      albumTitle: "Album \(title)", durationSeconds: durationSec,
                      filePath: "/tmp/\(title).wav", youTubeId: nil,
                      artworkHash: nil, artworkUrl: nil,
                      sampleRate: 44100, bitDepth: 16, codec: "pcm", isLossless: false)
    }

    /// 构造一个绑定了 `modelContext` 的 `QueueService`(用于 persist/restore)。
    private func makeQueue(container: ModelContainer) -> QueueService {
        let q = QueueService()
        q.modelContext = container.mainContext
        return q
    }

    private func makePlayback(queue: QueueService) -> (PlaybackService, RecordingEngine) {
        let local = RecordingEngine()
        let svc = PlaybackService(localEngine: local, youtubeEngine: RecordingEngine(), queue: queue)
        return (svc, local)
    }

    private func fetchSessions(_ container: ModelContainer) -> [ListeningSession] {
        let ctx = ModelContext(container)
        return (try? ctx.fetch(FetchDescriptor<ListeningSession>())) ?? []
    }

    private func queueStateRow(_ container: ModelContainer) -> QueueState? {
        let ctx = ModelContext(container)
        return (try? ctx.fetch(FetchDescriptor<QueueState>()))?
            .first(where: { $0.id == QueueState.sharedID })
    }

    // MARK: - 模型

    @Test("ListeningSession 持久化往返 + status 计算属性")
    func sessionRoundTrip() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let s = ListeningSession(startedAt: Date(timeIntervalSince1970: 1000),
                                 status: .active, currentTrackId: UUID(),
                                 currentPositionMs: 12_000)
        ctx.insert(s)
        try ctx.save()
        let fetched = try ctx.fetch(FetchDescriptor<ListeningSession>()).first
        #expect(fetched?.status == .active)
        #expect(fetched?.currentPositionMs == 12_000)
        #expect(fetched?.currentTrackId != nil)
        #expect(fetched?.endedAt == nil)
    }

    @Test("ListeningSession 表已加入 schema(空查询成功)")
    func schemaIncludesListeningSession() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        #expect(try ctx.fetch(FetchDescriptor<ListeningSession>()).isEmpty)
    }

    // MARK: - 事件 → 会话生命周期

    @Test("trackStarted 开启 active 会话 + checkpoint 崩溃恢复槽(位置 0)")
    func trackStartedOpensSession() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let q = makeQueue(container: container)
        let (playback, _) = makePlayback(queue: q)
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { true })

        let id = UUID()
        bus.post(.trackStarted(snap("A", id: id)))

        let sessions = fetchSessions(container)
        #expect(sessions.count == 1)
        #expect(sessions[0].status == .active)
        #expect(sessions[0].currentTrackId == id)
        #expect(sessions[0].currentPositionMs == 0)
        // 崩溃恢复槽同步写入 QueueState 单行
        let row = queueStateRow(container)
        #expect(row?.currentTrackId == id)
        #expect(row?.lastPositionMs == 0)
        _ = svc
    }

    @Test("后续 trackStarted 继续同一会话(更新曲目,不新建行)")
    func subsequentTrackStartedContinuesSession() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let q = makeQueue(container: container)
        let (playback, _) = makePlayback(queue: q)
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { true })

        let a = UUID(), b = UUID()
        bus.post(.trackStarted(snap("A", id: a)))
        bus.post(.trackStarted(snap("B", id: b)))

        let sessions = fetchSessions(container)
        #expect(sessions.count == 1)            // 仍是同一条会话
        #expect(sessions[0].currentTrackId == b) // 当前曲目更新为 B
        #expect(sessions[0].currentPositionMs == 0)
        _ = svc
    }

    @Test("trackSeeked 更新会话位置 + 崩溃恢复槽")
    func seekCheckpointsPosition() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let q = makeQueue(container: container)
        let (playback, _) = makePlayback(queue: q)
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { true })

        let id = UUID()
        bus.post(.trackStarted(snap("A", id: id)))
        bus.post(.trackSeeked(trackId: id, toMs: 65_000))

        let sessions = fetchSessions(container)
        #expect(sessions.count == 1)
        #expect(sessions[0].currentPositionMs == 65_000)
        let row = queueStateRow(container)
        #expect(row?.lastPositionMs == 65_000)
        _ = svc
    }

    @Test("trackCompleted + 队列耗尽(.off 末位、无插队)→ 结束会话")
    func completionWithExhaustionEndsSession() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let q = makeQueue(container: container)
        // 直接置队列为单曲目、末位、.off、upNext 空
        let a = snap("A")
        q.items = [QueueItem(id: UUID(), track: a, source: .local, queuedAt: .init(), fromContext: .songs)]
        q.currentIndex = 0
        q.upNext = []
        q.repeatMode = .off

        let (playback, _) = makePlayback(queue: q)
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { true })

        bus.post(.trackStarted(a))
        #expect(fetchSessions(container).first?.status == .active)
        bus.post(.trackCompleted(a, listenedMs: 200_000))

        let sessions = fetchSessions(container)
        #expect(sessions.count == 1)
        #expect(sessions[0].status == .ended)
        #expect(sessions[0].endedAt != nil)
        _ = svc
    }

    @Test("trackCompleted 但仍有下一首 → 会话保持 active")
    func completionWithoutExhaustionKeepsActive() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let q = makeQueue(container: container)
        let a = snap("A"), b = snap("B")
        q.items = [
            QueueItem(id: UUID(), track: a, source: .local, queuedAt: .init(), fromContext: .songs),
            QueueItem(id: UUID(), track: b, source: .local, queuedAt: .init(), fromContext: .songs)
        ]
        q.currentIndex = 0
        q.upNext = []
        q.repeatMode = .off

        let (playback, _) = makePlayback(queue: q)
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { true })

        bus.post(.trackStarted(a))
        bus.post(.trackCompleted(a, listenedMs: 200_000))
        #expect(fetchSessions(container).first?.status == .active)
        _ = svc
    }

    // MARK: - 功能开关闭合

    @Test("ffSessions 关闭:trackStarted 不落库、pendingRestore 仍为 nil")
    func disabledFlagNoOps() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let q = makeQueue(container: container)
        let (playback, _) = makePlayback(queue: q)
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { false })

        bus.post(.trackStarted(snap("A")))
        #expect(fetchSessions(container).isEmpty)
        #expect(svc.pendingRestore == nil)
        _ = svc
    }

    // MARK: - 启动恢复

    private func seedRestorable(container: ModelContainer, track: TrackSnapshot,
                                positionMs: Double, updatedAt: Date = .init()) {
        let ctx = ModelContext(container)
        // 队列单行:含该曲目、currentIndex 0 + 崩溃恢复槽
        let itemsJSON = (try? String(data: JSONEncoder().encode(
            [QueueItem(id: UUID(), track: track, source: .local, queuedAt: .init(), fromContext: .songs)]),
            encoding: .utf8)) ?? "[]"
        let row = QueueState(itemsJSON: itemsJSON, currentIndex: 0,
                            upNextJSON: "[]", historyJSON: "[]",
                            repeatModeRaw: RepeatMode.off.rawValue, shuffle: false,
                            currentTrackId: track.id, lastPositionMs: positionMs)
        ctx.insert(row)
        // active 会话行
        let session = ListeningSession(startedAt: updatedAt.addingTimeInterval(-60),
                                       updatedAt: updatedAt, status: .active,
                                       currentTrackId: track.id, currentPositionMs: positionMs)
        ctx.insert(session)
        try? ctx.save()
    }

    @Test("启动恢复:检测到未结束会话 → pendingRestore 含标题/位置;接管 activeSessionId")
    func restoreOffersPending() throws {
        let container = try makeContainer()
        let track = snap("LateNight", id: UUID())
        try seedRestorable(container: container, track: track, positionMs: 65_000)

        let q = makeQueue(container: container)
        q.restore()  // 复刻 MusesApp:先 restore 队列
        #expect(q.current()?.track.id == track.id)
        #expect(q.lastPositionMs == 65_000)

        let bus = PlaybackEventBus()
        let (playback, _) = makePlayback(queue: q)
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { true })

        let offer = try #require(svc.pendingRestore)
        #expect(offer.trackTitle == "LateNight")
        #expect(offer.artist == "Artist LateNight")
        #expect(offer.positionMs == 65_000)
        #expect(offer.displayText.contains("1:05"))  // 65s
        _ = svc
    }

    @Test("continuePendingSession:加载当前曲目并 seek 到恢复位(clamp 到 duration-2s)")
    func continueResumesAtPosition() async throws {
        let container = try makeContainer()
        let track = snap("Resume", id: UUID(), durationSec: 200)
        try seedRestorable(container: container, track: track, positionMs: 65_000)

        let q = makeQueue(container: container)
        q.restore()
        let bus = PlaybackEventBus()
        let (playback, local) = makePlayback(queue: q)
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { true })

        #expect(svc.pendingRestore != nil)
        svc.continuePendingSession()
        // resumeCurrent 起一个 Task 执行 loadCurrent → load → seek 消费
        try await Task.sleep(for: .milliseconds(150))

        #expect(svc.pendingRestore == nil)
        #expect(local.loadCallCount == 1)
        #expect(local.lastLoadedTrack?.id == track.id)
        // 65s 在 [0, 198s] 内,不被 clamp
        #expect(local.lastSeekTime != nil)
        #expect(abs((local.lastSeekTime ?? -1) - 65.0) < 0.01)
    }

    @Test("continuePendingSession:恢复位超出 duration-2s 时 clamp")
    func continueClampsToDurationMinus2() async throws {
        let container = try makeContainer()
        let track = snap("Resume", id: UUID(), durationSec: 200)
        try seedRestorable(container: container, track: track, positionMs: 210_000)  // 210s > 198s

        let q = makeQueue(container: container)
        q.restore()
        let bus = PlaybackEventBus()
        let (playback, local) = makePlayback(queue: q)
        // RecordingEngine.load 不设置 duration(真实引擎从音频文件读取)。
        // 手动注入 duration,使 PlaybackService 的 clamp 条件 `state.duration > 0` 成立,
        // 与 Phase17HistoryTests:278 同样的桩注入手法。
        local.state.duration = 200
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { true })

        svc.continuePendingSession()
        try await Task.sleep(for: .milliseconds(150))

        // clamp 到 duration(200)-2 = 198s
        #expect(abs((local.lastSeekTime ?? -1) - 198.0) < 0.01)
    }

    @Test("discardPendingSession:结束会话 + 清空崩溃恢复槽")
    func discardEndsAndClearsSlots() throws {
        let container = try makeContainer()
        let track = snap("Discard", id: UUID())
        try seedRestorable(container: container, track: track, positionMs: 30_000)

        let q = makeQueue(container: container)
        q.restore()
        let bus = PlaybackEventBus()
        let (playback, _) = makePlayback(queue: q)
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { true })

        #expect(svc.pendingRestore != nil)
        svc.discardPendingSession()
        #expect(svc.pendingRestore == nil)

        let sessions = fetchSessions(container)
        #expect(sessions.first?.status == .ended)
        let row = queueStateRow(container)
        #expect(row?.currentTrackId == nil)
        #expect(row?.lastPositionMs == nil)
        _ = svc
    }

    @Test("陈旧会话(>2h 未更新)不弹恢复并自动结束")
    func staleSessionNotOffered() throws {
        let container = try makeContainer()
        let track = snap("Stale", id: UUID())
        let stale = Date().addingTimeInterval(-3 * 3600)  // 3h ago
        try seedRestorable(container: container, track: track, positionMs: 10_000, updatedAt: stale)

        let q = makeQueue(container: container)
        q.restore()
        let bus = PlaybackEventBus()
        let (playback, _) = makePlayback(queue: q)
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { true })

        #expect(svc.pendingRestore == nil)
        let sessions = fetchSessions(container)
        #expect(sessions.first?.status == .ended)
        _ = svc
    }

    @Test("崩溃遗留多条 active:仅保留最新,其余被结束")
    func multipleActiveCollapsesToLatest() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let track = snap("Multi", id: UUID())
        let itemsJSON = (try? String(data: JSONEncoder().encode(
            [QueueItem(id: UUID(), track: track, source: .local, queuedAt: .init(), fromContext: .songs)]),
            encoding: .utf8)) ?? "[]"
        let row = QueueState(itemsJSON: itemsJSON, currentIndex: 0,
                            upNextJSON: "[]", historyJSON: "[]",
                            repeatModeRaw: RepeatMode.off.rawValue, shuffle: false,
                            currentTrackId: track.id, lastPositionMs: 5_000)
        ctx.insert(row)
        // 两条 active:旧 + 新
        let older = ListeningSession(startedAt: Date().addingTimeInterval(-7200),
                                      updatedAt: Date().addingTimeInterval(-7100), status: .active)
        let newer = ListeningSession(startedAt: Date().addingTimeInterval(-600),
                                      updatedAt: Date().addingTimeInterval(-500), status: .active,
                                      currentTrackId: track.id, currentPositionMs: 5_000)
        ctx.insert(older); ctx.insert(newer)
        try? ctx.save()

        let q = makeQueue(container: container)
        q.restore()
        let bus = PlaybackEventBus()
        let (playback, _) = makePlayback(queue: q)
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { true })

        #expect(svc.pendingRestore != nil)            // 最新的被 offered
        let actives = fetchSessions(container).filter { $0.status == .active }
        #expect(actives.count == 1)
        _ = svc
    }

    @Test("无可恢复会话:pendingRestore 为 nil")
    func noRestorableSessionYieldsNil() throws {
        let container = try makeContainer()
        let q = makeQueue(container: container)
        // 不 seed 任何会话/队列
        let bus = PlaybackEventBus()
        let (playback, _) = makePlayback(queue: q)
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { true })
        #expect(svc.pendingRestore == nil)
        _ = svc
    }
}