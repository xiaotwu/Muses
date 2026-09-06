import Foundation
import SwiftData

/// Listening history service (Final Spec §10.3 Feature 3 — Smart Listening History).
///
/// Subscribes to `PlaybackEventBus` and translates playback lifecycle events into persisted
/// `ListeningEvent` rows:
/// - `.trackStarted` → opens an "in progress" event (caching startedAt + track metadata).
/// - `.trackCompleted` / `.trackSkipped` / `.trackStopped` → closes the in-progress event and
///   persists it (outcome is completed / skipped / stopped respectively; listenedMs is carried
///   by the event).
/// - If a new `.trackStarted` overwrites an unclosed previous event → that event is closed
///   with an `interrupted` fallback (should not happen on the normal path; it only guards
///   against lost displacement events).
///
/// `listenedMs` and skip detection are computed by `PlaybackService` when it posts the event
/// (it owns `state.position`); this service never polls position, avoiding the observer
/// runaway risk seen in `NowPlayingManager`.
///
/// Feature flag: `PrefKey.ffSmartHistory` (off by default). When off, event boundaries are
/// still tracked but nothing is persisted, so toggling the setting does not lose the
/// in-progress listening boundary.
@Observable
@MainActor
final class HistoryService {
    private let modelContainer: ModelContainer
    private let eventBus: PlaybackEventBus
    private let enabledProvider: () -> Bool
    /// §10.2: listening-context provider (defaults to nil, i.e. no context attached).
    /// Production injects `contextService.capture()` via `MusesApp`; with ffContext off,
    /// capture returns nil.
    private let contextProvider: () -> ListeningContext?
    private var subscription: UUID?
    /// The current in-progress event: trackStarted received but not yet closed by a terminal event.
    private var pending: PendingEvent?
    /// Persistence counter: bumped on every write/clear so `HistoryView` recomputes
    /// (tracked via @Observable).
    private(set) var historyRevision: Int = 0

    /// Whether history is enabled (reads the live flag source so Settings toggles take
    /// effect immediately, with no extra wiring).
    var isEnabled: Bool { enabledProvider() }

    /// `enabledProvider` reads `UserDefaults` live by default (production); tests can inject a fixed value for isolation.
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

    /// Read-only container access: lets `HistoryView.replay` fetch `Track` snapshots by trackId.
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

    // MARK: - Event handling

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
            // Not handled at this granularity; pause/resume/seek may later feed behavioral profiling.
            break
        }
    }

    /// A new track starts: if an older event is still unclosed, close it with the interrupted fallback.
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

    /// Closes the in-progress event (snap comes from the terminal event and carries the latest track metadata).
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

    /// Fallback for a lost displacement event: persists one interrupted row using the metadata cached in pending.
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
            AppLog.for("HistoryService").warning("Failed to save ListeningEvent: \(error.localizedDescription)")
        }
        historyRevision &+= 1
    }

    // MARK: - Queries

    /// Returns history events matching the filter (descending by startedAt, default 200).
    /// Some predicates are hard to express in SwiftData, so it fetches first and filters after.
    /// Sufficient until the event count reaches 100k+; a dedicated performance task would then
    /// add `@Index` and predicate pushdown (a minor change allowed by Final Spec §15).
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

    /// Total event count (used by HistoryView's title/empty-state logic).
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

    /// Clears all history (used by HistoryView's "Clear History" button). Irreversible.
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

    // MARK: - Recap aggregation

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

    // MARK: - Context profiles (Final Spec §10.2)

    /// Aggregates local profiles from `ListeningEvent.contextSummaryJSON`: per-app /
    /// late-night / morning / headphone / weekend. Only events with context are counted;
    /// events without context are skipped.
    func contextProfiles(now: Date = Date(), limit: Int = 50_000) -> [ListeningContextProfile] {
        let evs = events(matching: HistoryQuery(limit: limit))
        // Decode context and bucket events by profile dimension.
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

    /// Builds one profile: aggregates playCount plus the top 5 tracks (descending by plays).
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

    /// Frontmost-app display name: uses the last segment of the bundle id as a friendly name
    /// (no network resolution, avoiding privacy/performance cost).
    private func appLabel(_ bundleId: String) -> String {
        let segments = bundleId.split(separator: ".")
        let last = segments.last.map(String.init) ?? bundleId
        return tr("Most played while \(last)", "使用 \(last) 时最爱")
    }
}

/// Recap time range. `allTime` starts from the earliest event.
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
