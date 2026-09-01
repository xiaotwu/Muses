import Foundation
import SwiftData

/// 收听历史服务(Final Spec §10.3 Feature 3 — Smart Listening History)。
///
/// 订阅 `PlaybackEventBus`,把播放生命周期翻译成持久化的 `ListeningEvent` 行:
/// - `.trackStarted` → 开启一条「进行中」事件(缓存 startedAt + 曲目元数据)。
/// - `.trackCompleted` / `.trackSkipped` / `.trackStopped` → 终结当前进行中事件并落库
///   (outcome 分别为 completed / skipped / stopped;listenedMs 由事件携带)。
/// - 若新 `.trackStarted` 覆盖了未终结的旧事件 → 以 `interrupted` 兜底终结(正常路径不会发生,
///   仅供位移事件丢失时使用)。
///
/// `listenedMs` 与跳过判定由 `PlaybackService` 在发出事件时完成(它持有 `state.position`),
/// 本服务不做位置轮询,避免重蹈 `NowPlayingManager` 的观察 runaway 风险。
///
/// 功能开关:`PrefKey.ffSmartHistory`(默认关)。关闭时仍跟踪事件边界但不落库,
/// 使设置切换不丢失进行中的收听边界。
@Observable
@MainActor
final class HistoryService {
    private let modelContainer: ModelContainer
    private let eventBus: PlaybackEventBus
    private let enabledProvider: () -> Bool
    /// Phase 23 §10.2:收听上下文提供者(默认 nil,即不附加上下文)。
    /// 生产由 `MusesApp` 注入 `contextService.capture()`;关闭 ffContext 时 capture 返回 nil。
    private let contextProvider: () -> ListeningContext?
    private var subscription: UUID?
    /// 当前进行中事件:已收到 trackStarted 但尚未被终结事件关闭。
    private var pending: PendingEvent?
    /// 落库计数器:每次写入/清空自增,供 `HistoryView` 触发重算(@Observable 追踪)。
    private(set) var historyRevision: Int = 0

    /// 历史是否启用(实时读开关源,使 Settings 切换即时生效,无需额外接线)。
    var isEnabled: Bool { enabledProvider() }

    /// `enabledProvider` 默认实时读 `UserDefaults`(生产),测试可注入固定值以保持隔离。
    init(modelContainer: ModelContainer, eventBus: PlaybackEventBus,
         enabledProvider: @escaping () -> Bool = {
        UserDefaults.standard.bool(forKey: PrefKey.ffSmartHistory)
    },
         contextProvider: @escaping () -> ListeningContext? = { nil }) {
        self.modelContainer = modelContainer
        self.eventBus = eventBus
        self.enabledProvider = enabledProvider
        self.contextProvider = contextProvider
        subscribe()
    }

    /// 只读容器访问:供 `HistoryView.replay` 按 trackId 取 `Track` 快照。
    var container: ModelContainer { modelContainer }

    struct PendingEvent: Sendable {
        let trackId: UUID
        let trackTitle: String
        let artist: String
        let albumTitle: String?
        let startedAt: Date
        let durationMs: Double
    }

    private func subscribe() {
        subscription = eventBus.subscribe { [weak self] event in
            self?.handle(event)
        }
    }

    // MARK: - 事件处理

    private func handle(_ event: PlaybackEvent) {
        switch event {
        case .trackStarted(let snap):
            open(snap)
        case .trackCompleted(let snap, let listenedMs):
            close(snap: snap, listenedMs: Int(listenedMs), outcome: .completed)
        case .trackSkipped(let snap, let listenedMs):
            close(snap: snap, listenedMs: Int(listenedMs), outcome: .skipped)
        case .trackStopped(let snap, let listenedMs):
            close(snap: snap, listenedMs: Int(listenedMs), outcome: .stopped)
        case .trackPaused, .trackResumed, .trackSeeked, .queueChanged,
             .outputDeviceChanged,
             .focusSessionStarted, .focusSessionEnded:
            // Phase 17 不细分;Phase 23 Context 可能利用 pause/resume/seek 做行为画像。
            break
        }
    }

    /// 新曲目开始:若仍有未终结的旧事件,以 interrupted 兜底关闭。
    private func open(_ snap: TrackSnapshot) {
        if let p = pending, p.trackId != snap.id {
            closeInterrupted(p)
        }
        pending = PendingEvent(
            trackId: snap.id, trackTitle: snap.title, artist: snap.artist,
            albumTitle: snap.albumTitle,
            startedAt: Date(), durationMs: snap.durationSeconds * 1000.0
        )
    }

    /// 终结当前进行中事件(snap 来自终结事件,携带最新曲目元数据)。
    private func close(snap: TrackSnapshot, listenedMs: Int, outcome: ListeningOutcome) {
        let startedAt = (pending?.trackId == snap.id) ? pending!.startedAt : Date()
        let durMs = snap.durationSeconds * 1000.0
        let ratio: Double? = durMs > 0 ? Double(listenedMs) / durMs : nil
        let event = ListeningEvent(
            trackId: snap.id, trackTitle: snap.title, artist: snap.artist,
            albumTitle: snap.albumTitle,
            startedAt: startedAt, endedAt: Date(),
            listenedMs: listenedMs, completionRatio: ratio, outcome: outcome,
            contextSummaryJSON: ContextService.encode(contextProvider())
        )
        persist(event)
        if pending?.trackId == snap.id { pending = nil }
    }

    /// 位移事件丢失的兜底:用 pending 缓存的元数据落库一条 interrupted。
    private func closeInterrupted(_ p: PendingEvent) {
        guard isEnabled else { pending = nil; return }
        let ratio: Double? = p.durationMs > 0 ? 0.0 : nil
        let event = ListeningEvent(
            trackId: p.trackId, trackTitle: p.trackTitle, artist: p.artist,
            albumTitle: p.albumTitle,
            startedAt: p.startedAt, endedAt: Date(),
            listenedMs: 0, completionRatio: ratio, outcome: .interrupted,
            contextSummaryJSON: ContextService.encode(contextProvider())
        )
        persist(event)
    }

    private func persist(_ event: ListeningEvent) {
        guard isEnabled else { return }
        let ctx = ModelContext(modelContainer)
        ctx.insert(event)
        do { try ctx.save() } catch {
            AppLog.for("HistoryService").warning("保存 ListeningEvent 失败:\(error.localizedDescription)")
        }
        historyRevision &+= 1
    }

    // MARK: - 查询

    /// 按过滤器返回历史事件(按 startedAt 倒序,默认 200 条)。
    /// 部分谓词在 SwiftData 表达受限,采用「先取后筛」;事件量级达到 100k+ 前足够,
    /// 届时再以独立性能加固任务引入 `@Index` 与谓词下推(Final Spec §15 允许的次要变更)。
    func events(matching query: HistoryQuery = HistoryQuery()) -> [ListeningEvent] {
        let ctx = ModelContext(modelContainer)
        var desc = FetchDescriptor<ListeningEvent>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        desc.fetchLimit = query.limit
        let all = (try? ctx.fetch(desc)) ?? []
        return all.filter { ev in
            if let o = query.outcome, ev.outcome != o { return false }
            if let f = query.fromDate, ev.startedAt < f { return false }
            if let t = query.toDate, ev.startedAt > t { return false }
            if let q = query.titleContains, !q.isEmpty,
               !ev.trackTitle.localizedCaseInsensitiveContains(q) { return false }
            if let q = query.artistContains, !q.isEmpty,
               !ev.artist.localizedCaseInsensitiveContains(q) { return false }
            if let q = query.albumContains, !q.isEmpty {
                guard let album = ev.albumTitle,
                      album.localizedCaseInsensitiveContains(q) else { return false }
            }
            return true
        }
    }

    /// 事件总数(供 HistoryView 标题/空状态判断)。
    func eventCount() -> Int {
        let ctx = ModelContext(modelContainer)
        return (try? ctx.fetchCount(FetchDescriptor<ListeningEvent>())) ?? 0
    }

    /// Loads the full History presentation from one successful fetch. Unlike
    /// the legacy convenience queries, this API intentionally propagates store
    /// failures so the screen can render an error state instead of "no plays".
    func dashboard(range: RecapRange, now: Date = .init(), recentLimit: Int = 80) throws
        -> ListeningHistoryDashboard {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<ListeningEvent>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        let all = try context.fetch(descriptor)
        let timeline = all.map(Self.timelineSnapshot)
        let earliest = timeline.map(\.startedAt).min()
        let displayInterval = range.displayInterval(from: now, calendar: .current,
                                                    earliest: earliest)
        let dataInterval = DateInterval(start: displayInterval.start,
                                        end: min(now, displayInterval.end))
        let scoped = timeline.compactMap {
            ListeningHeatmapBuilder.clipped($0, to: dataInterval)
        }
        return ListeningHistoryDashboard(
            recap: Self.makeRecap(events: scoped, rangeLabel: range.label),
            heatmap: ListeningHeatmapBuilder.build(events: timeline, range: range,
                                                   now: now, calendar: .current),
            // The timeline must use exactly the same calendar interval as the
            // recap and heatmap. Showing an older play under a selected empty
            // range makes the screen look contradictory.
            recent: all.filter { event in
                let end = max(event.startedAt, event.endedAt ?? event.startedAt)
                return event.startedAt < dataInterval.end && end > dataInterval.start
            }
            .prefix(max(1, recentLimit)).map {
                ListeningEventSnapshot(
                    id: $0.id, trackId: $0.trackId, title: $0.trackTitle,
                    artist: $0.artist, albumTitle: $0.albumTitle,
                    startedAt: $0.startedAt, listenedMs: $0.listenedMs,
                    outcome: $0.outcome
                )
            },
            totalEventCount: all.count
        )
    }

    /// 清空全部历史(供 HistoryView「清除历史」按钮)。不可恢复。
    func clearAll() {
        let ctx = ModelContext(modelContainer)
        try? ctx.delete(model: ListeningEvent.self)
        try? ctx.save()
        historyRevision &+= 1
    }

    func clearAllReporting() throws {
        let context = ModelContext(modelContainer)
        try context.delete(model: ListeningEvent.self)
        try context.save()
        historyRevision &+= 1
    }

    // MARK: - 回顾汇总

    func recap(range: RecapRange, now: Date = Date()) -> ListeningRecap {
        let timeline = events(matching: HistoryQuery(limit: 100_000))
            .map(Self.timelineSnapshot)
        let earliest = timeline.map(\.startedAt).min()
        let displayInterval = range.displayInterval(from: now, calendar: .current,
                                                    earliest: earliest)
        let dataInterval = DateInterval(start: displayInterval.start,
                                        end: min(now, displayInterval.end))
        let scoped = timeline.compactMap {
            ListeningHeatmapBuilder.clipped($0, to: dataInterval)
        }
        return Self.makeRecap(events: scoped, rangeLabel: range.label)
    }

    private nonisolated static func makeRecap(events evs: [ListeningTimelineEvent],
                                               rangeLabel: String) -> ListeningRecap {
        var totalMs = 0, completed = 0, skipped = 0
        var trackPlays: [UUID: (title: String, artist: String, plays: Int, ms: Int)] = [:]
        var artistPlays: [String: (plays: Int, ms: Int)] = [:]
        for ev in evs {
            totalMs += ev.listenedMs
            if ev.outcome == .completed { completed += 1 }
            if ev.outcome == .skipped { skipped += 1 }
            var tt = trackPlays[ev.trackId] ?? (ev.title, ev.artist, 0, 0)
            tt.plays += 1; tt.ms += ev.listenedMs
            trackPlays[ev.trackId] = tt
            var at = artistPlays[ev.artist] ?? (0, 0)
            at.plays += 1; at.ms += ev.listenedMs
            artistPlays[ev.artist] = at
        }
        let topTracks = trackPlays.map { ListeningRecap.TrackTally(id: $0.key, title: $0.value.title, artist: $0.value.artist, plays: $0.value.plays, listenedMs: $0.value.ms) }
            .sorted { $0.plays > $1.plays || ($0.plays == $1.plays && $0.listenedMs > $1.listenedMs) }
            .prefix(10)
        let topArtists = artistPlays.map { ListeningRecap.ArtistTally(id: $0.key, name: $0.key, plays: $0.value.plays, listenedMs: $0.value.ms) }
            .sorted { $0.plays > $1.plays || ($0.plays == $1.plays && $0.listenedMs > $1.listenedMs) }
            .prefix(10)
        return ListeningRecap(
            rangeLabel: rangeLabel,
            totalListenedMs: totalMs, eventCount: evs.count,
            completedCount: completed, skippedCount: skipped,
            uniqueTracks: trackPlays.count, uniqueArtists: artistPlays.count,
            topTracks: Array(topTracks), topArtists: Array(topArtists)
        )
    }

    private nonisolated static func timelineSnapshot(_ event: ListeningEvent)
        -> ListeningTimelineEvent {
        .init(id: event.id, trackId: event.trackId,
              title: event.trackTitle, artist: event.artist,
              startedAt: event.startedAt, endedAt: event.endedAt,
              listenedMs: event.listenedMs,
              outcome: event.outcome)
    }

    // MARK: - 上下文画像(Final Spec §10.2)

    /// 从 `ListeningEvent.contextSummaryJSON` 聚合本地画像:per-app / late-night / morning /
    /// headphone / weekend。仅统计有上下文的事件;无上下文的事件跳过。
    func contextProfiles(now: Date = Date(), limit: Int = 50_000) -> [ListeningContextProfile] {
        let evs = events(matching: HistoryQuery(limit: limit))
        // 解码上下文并按画像维度分桶。
        var perApp: [String: [(ListeningEvent, ListeningContext)]] = [:]
        var lateNight: [(ListeningEvent, ListeningContext)] = []
        var morning: [(ListeningEvent, ListeningContext)] = []
        var headphone: [(ListeningEvent, ListeningContext)] = []
        var weekend: [(ListeningEvent, ListeningContext)] = []
        for ev in evs {
            guard let ctx = ContextService.decode(ev.contextSummaryJSON) else { continue }
            if let bid = ctx.frontmostAppBundleId {
                perApp[bid, default: []].append((ev, ctx))
            }
            switch ctx.timeBand {
            case .lateNight: lateNight.append((ev, ctx))
            case .morning:   morning.append((ev, ctx))
            default: break
            }
            if ctx.isHeadphones == true { headphone.append((ev, ctx)) }
            if ctx.isWeekend { weekend.append((ev, ctx)) }
        }
        var profiles: [ListeningContextProfile] = []
        for (bid, items) in perApp.sorted(by: { $0.value.count > $1.value.count }) {
            profiles.append(makeProfile(id: "app:\(bid)", label: appLabel(bid), items: items))
        }
        if !lateNight.isEmpty { profiles.append(makeProfile(id: "band:lateNight", label: tr("Late-night favorites", "深夜最爱"), items: lateNight)) }
        if !morning.isEmpty { profiles.append(makeProfile(id: "band:morning", label: tr("Morning tracks", "晨间曲目"), items: morning)) }
        if !headphone.isEmpty { profiles.append(makeProfile(id: "headphone", label: tr("Headphone favorites", "耳机最爱"), items: headphone)) }
        if !weekend.isEmpty { profiles.append(makeProfile(id: "weekend", label: tr("Weekend albums", "周末专辑"), items: weekend)) }
        return profiles
    }

    /// 生成单个画像:聚合 playCount + top 5 曲目(按播放数倒序)。
    private func makeProfile(id: String, label: String, items: [(ListeningEvent, ListeningContext)]) -> ListeningContextProfile {
        var plays: [UUID: (title: String, artist: String, plays: Int)] = [:]
        for (ev, _) in items {
            var t = plays[ev.trackId] ?? (ev.trackTitle, ev.artist, 0)
            t.plays += 1
            plays[ev.trackId] = t
        }
        let top = plays.sorted { $0.value.plays > $1.value.plays }
            .prefix(5)
            .map { ListeningContextProfile.ContextProfileTrack(id: $0.key, title: $0.value.title, artist: $0.value.artist, plays: $0.value.plays) }
        return ListeningContextProfile(id: id, label: label, playCount: items.count, topTracks: Array(top))
    }

    /// 前台应用展示名:取 bundle id 最后一段作为友好名(不联网解析,避免隐私/性能负担)。
    private func appLabel(_ bundleId: String) -> String {
        let segments = bundleId.split(separator: ".")
        let last = segments.last.map(String.init) ?? bundleId
        return tr("Most played while \(last)", "使用 \(last) 时最爱")
    }
}

/// 回顾时间范围。`allTime` 自最早事件起。
enum RecapRange: String, CaseIterable, Sendable, Equatable {
    case day, week, month, allTime

    var label: String {
        switch self {
        case .day: tr("Today", "今天")
        case .week: tr("This Week", "本周")
        case .month: tr("This Month", "本月")
        case .allTime: tr("All Time", "全部")
        }
    }

    func startDate(from now: Date, calendar: Calendar = .current) -> Date {
        displayInterval(from: now, calendar: calendar, earliest: nil).start
    }

    func displayInterval(from now: Date, calendar: Calendar = .current,
                         earliest: Date?) -> DateInterval {
        switch self {
        case .day:
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
            return .init(start: start, end: end)
        case .week:
            if let value = calendar.dateInterval(of: .weekOfYear, for: now) { return value }
            let start = calendar.startOfDay(for: now)
            return .init(start: start,
                         end: calendar.date(byAdding: .day, value: 7, to: start) ?? now)
        case .month:
            if let value = calendar.dateInterval(of: .month, for: now) { return value }
            let start = calendar.startOfDay(for: now)
            return .init(start: start,
                         end: calendar.date(byAdding: .month, value: 1, to: start) ?? now)
        case .allTime:
            let start = calendar.startOfDay(for: earliest ?? now)
            let end = calendar.date(byAdding: .day, value: 1,
                                    to: calendar.startOfDay(for: now)) ?? now
            return .init(start: start, end: end)
        }
    }
}
