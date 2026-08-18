import Foundation
import SwiftData
import AppKit

/// 收听会话服务(Final Spec §10.5 Feature 5 — Listening Sessions + Crash Recovery)。
///
/// 职责:
/// - 订阅 `PlaybackEventBus`,把播放生命周期翻译成「会话」:`.trackStarted` 开启/继续一条
///   `active` 会话(快照队列 + 记 currentTrack);`.trackPaused`/`.trackStopped`/`.trackSkipped`/
///   `.trackCompleted`/`.trackSeeked` 触发 checkpoint(更新会话行的 position + 同步写入
///   `QueueState` 崩溃恢复槽);队列耗尽时结束会话。
/// - 周期 ~10s checkpoint(仅在播放中),保证崩溃后位置误差 ≤ 10s。
/// - 启动恢复:构造时检测未结束会话,若满足恢复条件则暴露 `pendingRestore` 供 `RootView`
///   弹「继续 / 重新开始」;**绝不**静默替换用户的队列。
/// - 系统事件:`willSleep` 记住播放状态 + checkpoint;`didWake` 在睡眠前正在播放时恢复播放
///   (best-effort 重新同步引擎);`willTerminate` 做最后一次 checkpoint。
///
/// 功能开关:`PrefKey.ffSessions`(默认关)。关闭时不创建/更新会话、不弹恢复对话框、
/// 不安装系统观察的实际处理(观察器仍装着但 `handle*` 早退),保持现有「只 restore 队列、
/// 不恢复位置」的行为不变。
///
/// 与 `HistoryService` 互补:History 记「单曲事件」,Session 记「连续时段」+ 崩溃恢复。
@Observable
@MainActor
final class SessionService {
    private let modelContainer: ModelContainer
    private let eventBus: PlaybackEventBus
    private let playback: PlaybackService
    private let queue: QueueService
    private let enabledProvider: () -> Bool
    private var subscription: UUID?
    private var checkpointTimer: Task<Void, Never>?
    /// 系统观察者 token 装在独立的 `@unchecked Sendable` 盒子里:SessionService 是 `@MainActor`
    /// 类,其 deinit 是非隔离的,需在 deinit 中 `removeObserver`。盒子是 `let`(非隔离可访问),
    /// 内部可变属性由本类手动管理并发(仅在主线程 install、deinit 读取),故标 `@unchecked Sendable`。
    private let observerTokens = ObserverTokens()

    /// 当前 active 会话 id(内存镜像,避免每次事件都查库)。nil = 无进行中会话。
    private var activeSessionId: UUID?
    /// 只读访问当前进行中会话 id(Phase 25 FocusService 用以关联 FocusSession.listeningSessionId)。
    var currentSessionId: UUID? { activeSessionId }
    /// 睡眠前的播放状态,供唤醒时判断是否需恢复播放。
    private var wasPlayingBeforeSleep = false

    /// 启动时检测到的可恢复会话(供 `RootView` 弹恢复对话框)。nil = 无可恢复会话。
    private(set) var pendingRestore: RestoreOffer?

    var isEnabled: Bool { enabledProvider() }

    /// `enabledProvider` 默认实时读 `UserDefaults`(生产),测试可注入固定值以保持隔离。
    init(modelContainer: ModelContainer, eventBus: PlaybackEventBus,
         playback: PlaybackService, queue: QueueService,
         enabledProvider: @escaping () -> Bool = {
        UserDefaults.standard.bool(forKey: PrefKey.ffSessions)
    }) {
        self.modelContainer = modelContainer
        self.eventBus = eventBus
        self.playback = playback
        self.queue = queue
        self.enabledProvider = enabledProvider
        subscribe()
        startCheckpointTimer()
        installSystemObservers()
        checkForRestorableSession()
    }

    deinit {
        // 仅清理观察者注册;eventBus 订阅闭包持 `[weak self]`,对象释放后自动失效(no-op),
        // checkpointTimer 亦是 `[weak self]` 循环,下一轮 `guard let self` 即返回退出。
        // removeObserver 是线程安全的 ObjC 调用,可在非隔离 deinit 中使用。
        let tokens = observerTokens
        if let o = tokens.sleep { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let o = tokens.wake { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let o = tokens.terminate { NotificationCenter.default.removeObserver(o) }
    }

    /// 观察者 token 容器:可变属性由 `SessionService` 在主线程 install、deinit 读取,
    /// 手动保证无并发,故 `@unchecked Sendable`(deinit 非隔离访问 `let` 盒子本身安全)。
    final class ObserverTokens: @unchecked Sendable {
        var sleep: NSObjectProtocol?
        var wake: NSObjectProtocol?
        var terminate: NSObjectProtocol?
    }

    /// 启动恢复对话框的展示数据(标题/艺术家/恢复位置)。
    struct RestoreOffer: Sendable {
        let trackTitle: String
        let artist: String
        let positionMs: Double

        /// 本地化展示文本,如「从 1:23 继续 "Track — Artist"」。
        var displayText: String {
            let pos = Self.format(positionMs / 1000.0)
            return tr("Resume \"\(trackTitle) — \(artist)\" from \(pos)",
                      "从 \(pos) 继续「\(trackTitle) — \(artist)」")
        }

        static func format(_ seconds: Double) -> String {
            let total = max(0, Int(seconds))
            let m = total / 60, s = total % 60
            return String(format: "%d:%02d", m, s)
        }
    }

    // MARK: - 事件订阅

    private func subscribe() {
        subscription = eventBus.subscribe { [weak self] event in
            self?.handle(event)
        }
    }

    private func handle(_ event: PlaybackEvent) {
        guard isEnabled else { return }
        switch event {
        case .trackStarted(let snap):
            openOrContinueSession(for: snap)
        case .trackPaused, .trackStopped, .trackSkipped:
            checkpoint()
        case .trackCompleted:
            checkpoint()
            // 队列耗尽(.off 且在最后一首且无插队)→ 自然结束会话
            if queue.repeatMode == .off,
               queue.currentIndex >= queue.items.count - 1,
               queue.upNext.isEmpty {
                endActiveSession()
            }
        case .trackSeeked(_, let toMs):
            checkpoint(positionMs: toMs)
        case .trackResumed:
            break  // 恢复播放不改变曲目/位置边界,周期 timer 会继续 checkpoint
        case .queueChanged, .playbackSourceChanged, .outputDeviceChanged,
             .focusSessionStarted, .focusSessionEnded:
            break
        }
    }

    // MARK: - 会话生命周期

    /// 新曲目开始:继续当前 active 会话(更新曲目 + 快照)或新建一条。
    private func openOrContinueSession(for snap: TrackSnapshot) {
        let ctx = ModelContext(modelContainer)
        if let sid = activeSessionId,
           let row = (try? ctx.fetch(FetchDescriptor<ListeningSession>()))?
            .first(where: { $0.id == sid }), row.status == .active {
            row.currentTrackId = snap.id
            row.currentPositionMs = 0
            row.updatedAt = Date()
            row.queueSnapshotJSON = snapshotQueueJSON()
            try? ctx.save()
        } else {
            let session = ListeningSession(
                startedAt: Date(), status: .active,
                queueSnapshotJSON: snapshotQueueJSON(),
                currentTrackId: snap.id, currentPositionMs: 0)
            ctx.insert(session)
            try? ctx.save()
            activeSessionId = session.id
        }
        // 同步崩溃恢复槽到新曲目(位置 0)
        queue.checkpointPosition(currentTrackId: snap.id, lastPositionMs: 0)
    }

    /// checkpoint:把当前位置写入会话行 + `QueueState` 崩溃恢复槽。
    /// `positionMs` 显式传入时用之(seek 事件携带目标位);否则从 `playback.state.position` 折算。
    private func checkpoint(positionMs: Double? = nil) {
        guard let sid = activeSessionId else { return }
        let posMs = positionMs ?? (max(0, playback.state.position) * 1000.0)
        let trackId = playback.state.track?.id
        let ctx = ModelContext(modelContainer)
        guard let row = (try? ctx.fetch(FetchDescriptor<ListeningSession>()))?
            .first(where: { $0.id == sid }) else { return }
        row.currentPositionMs = posMs
        row.currentTrackId = trackId
        row.updatedAt = Date()
        try? ctx.save()
        // 崩溃恢复槽(QueueState 单行)是启动恢复实际读取的来源。
        queue.checkpointPosition(currentTrackId: trackId, lastPositionMs: posMs)
    }

    /// 结束当前 active 会话(队列耗尽 / 用户「重新开始」)。
    private func endActiveSession() {
        guard let sid = activeSessionId else { return }
        let ctx = ModelContext(modelContainer)
        if let row = (try? ctx.fetch(FetchDescriptor<ListeningSession>()))?
            .first(where: { $0.id == sid }) {
            row.statusRaw = SessionStatus.ended.rawValue
            row.endedAt = Date()
            row.updatedAt = Date()
            try? ctx.save()
        }
        activeSessionId = nil
    }

    /// 队列自包含快照(供会话回顾/审计;崩溃恢复用 QueueState 单行,不依赖此快照)。
    private func snapshotQueueJSON() -> String? {
        let snap = QueueSnapshotPayload(
            items: queue.items, upNext: queue.upNext, history: queue.history,
            currentIndex: queue.currentIndex,
            repeatMode: queue.repeatMode.rawValue, shuffle: queue.shuffle)
        return try? String(data: JSONEncoder().encode(snap), encoding: .utf8)
    }

    private struct QueueSnapshotPayload: Codable {
        let items: [QueueItem]
        let upNext: [QueueItem]
        let history: [QueueItem]
        let currentIndex: Int
        let repeatMode: String
        let shuffle: Bool
    }

    // MARK: - 周期 checkpoint(仅播放中,~10s)

    private func startCheckpointTimer() {
        checkpointTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                guard self.isEnabled,
                      self.activeSessionId != nil,
                      self.playback.state.isPlaying,
                      self.playback.state.track != nil else { continue }
                self.checkpoint()
            }
        }
    }

    // MARK: - 启动恢复

    /// 构造时调用:检测未结束会话,满足条件则暴露 `pendingRestore`;陈旧会话自动结束。
    private func checkForRestorableSession() {
        guard isEnabled else { return }
        let ctx = ModelContext(modelContainer)
        var desc = FetchDescriptor<ListeningSession>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        desc.fetchLimit = 64
        let sessions = (try? ctx.fetch(desc)) ?? []
        let active = sessions.filter { $0.status == .active }
        guard let latest = active.first else { return }
        // 防御:崩溃可能遗留多条 active,把多余的结束掉。
        for extra in active.dropFirst() {
            extra.statusRaw = SessionStatus.ended.rawValue
            extra.endedAt = Date()
        }
        // 陈旧(> 2h 未更新)→ 自动结束,不弹对话框(对应「长时空闲结束会话」)。
        if Date().timeIntervalSince(latest.updatedAt) > 2 * 3600 {
            latest.statusRaw = SessionStatus.ended.rawValue
            latest.endedAt = Date()
            try? ctx.save()
            return
        }
        try? ctx.save()
        // 需要队列里有当前曲目可恢复(`queue.restore()` 已在 MusesApp 中先于本服务执行)。
        guard queue.current() != nil,
              let snap = queue.current()?.track else { return }
        let posMs = latest.currentPositionMs ?? queue.lastPositionMs ?? 0
        activeSessionId = latest.id  // 接管这条会话,「继续」时在其上更新
        pendingRestore = RestoreOffer(trackTitle: snap.title, artist: snap.artist,
                                      positionMs: posMs)
    }

    /// 用户选择「继续」:在恢复位加载当前曲目并 seek。
    func continuePendingSession() {
        guard pendingRestore != nil else { return }
        let posMs = queue.lastPositionMs ?? pendingRestore?.positionMs ?? 0
        pendingRestore = nil
        guard queue.current() != nil else { return }
        playback.resumeCurrent(atMs: posMs)
    }

    /// 用户选择「重新开始」:结束会话 + 清空崩溃恢复槽(下次启动不自动恢复)。
    func discardPendingSession() {
        pendingRestore = nil
        endActiveSession()
        queue.clearCrashRecoverySlots()
    }

    /// 仅供恢复对话框绑定 `set:false`(Escape / 失焦关闭)时清掉展示态。
    /// 不结束会话、不清槽位——即「暂不决定」,下次启动仍会再次询问。
    func clearPendingRestore() {
        pendingRestore = nil
    }

    // MARK: - 系统事件(sleep / wake / terminate)

    private func installSystemObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        let tokens = observerTokens
        tokens.sleep = ws.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.handleSleep() } }
        tokens.wake = ws.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.handleWake() } }
        tokens.terminate = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.handleTerminate() } }
    }

    private func handleSleep() {
        guard isEnabled else { return }
        wasPlayingBeforeSleep = playback.state.isPlaying
        checkpoint()
    }

    private func handleWake() {
        guard isEnabled else { return }
        // best-effort 重新同步:睡眠前正在播放、当前已停 → 恢复播放。
        if wasPlayingBeforeSleep,
           playback.state.track != nil,
           !playback.state.isPlaying {
            playback.toggle()
        }
        checkpoint()
    }

    private func handleTerminate() {
        guard isEnabled else { return }
        checkpoint()
    }
}