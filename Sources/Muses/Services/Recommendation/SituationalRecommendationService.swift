import Foundation
import Observation
import SwiftData

/// Situational New recommendations.
///
/// "Music for you, right now": deterministic scoring (no LLM) over History/Context/Sessions/Focus/Inbox/Library/
/// imported YouTube tracks. Adds no new yt-dlp spawns.
///
/// Architecture (mirrors `RecommendationService`):
///  - The main actor projects service state into a `SituationalSnapshot` (fully Sendable values) once.
///  - The offline pure function `plan(from:)` runs on a `Task.detached` and never touches @Model.
///  - The main actor maps ids back to `TrackSnapshot`s.
///
/// `score = listeningAffinity + contextAffinity + recencyWeight + playlistAffinity
///         + discoveryWeight - recentOverplayPenalty - skipPenalty`
/// All weights are constants and deterministic/testable. Missing signals are never fabricated (no context → that dimension scores 0).
@MainActor
@Observable
final class SituationalRecommendationService {

    private let library: LibraryService
    private let historyService: HistoryService?
    private let inboxService: InboxService?
    private let modelContainer: ModelContainer?
    private let enabledProvider: () -> Bool
    /// Context signal injection: bridges `ContextService.capture()` by default; tests can inject values directly.
    private let contextProvider: () -> ListeningContext?
    /// Focus state injection: bridges `FocusService.isActive`/`activeSessionId` by default.
    private let focusStateProvider: () -> (active: Bool, sessionId: UUID?)

    init(library: LibraryService,
         historyService: HistoryService? = nil,
         contextService: ContextService? = nil,
         focusService: FocusService? = nil,
         inboxService: InboxService? = nil,
         modelContainer: ModelContainer? = nil,
         enabledProvider: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: PrefKey.ffSituationalNew) },
         contextProvider: (() -> ListeningContext?)? = nil,
         focusStateProvider: (() -> (active: Bool, sessionId: UUID?))? = nil) {
        self.library = library
        self.historyService = historyService
        self.inboxService = inboxService
        self.modelContainer = modelContainer
        self.enabledProvider = enabledProvider
        // Bridges the real services by default; tests can override. Weak closure references avoid retain cycles.
        if let contextProvider {
            self.contextProvider = contextProvider
        } else if let contextService {
            let cs = contextService
            self.contextProvider = { [weak cs] in cs?.capture() }
        } else {
            self.contextProvider = { nil }
        }
        if let focusStateProvider {
            self.focusStateProvider = focusStateProvider
        } else if let focusService {
            let fs = focusService
            self.focusStateProvider = { [weak fs] in (fs?.isActive ?? false, fs?.activeSessionId) }
        } else {
            self.focusStateProvider = { (false, nil) }
        }
    }

    var isEnabled: Bool { enabledProvider() }

    // MARK: - Public

    /// Computes the current situational recommendation sections. `ffSituationalNew` off → returns empty (NewView falls back to RecommendationService).
    func compute() async -> [SituationalSection] {
        guard isEnabled else { return [] }
        let snap = snapshot()
        let planned = await Task.detached(priority: .userInitiated) {
            Self.plan(from: snap)
        }.value
        return resolve(planned, snapshot: snap)
    }

    // MARK: - Snapshot

    /// Main-actor snapshot: projects @Model objects into Sendable values.
    private struct SituationalSnapshot: Sendable {
        struct TrackV: Sendable, Hashable {
            let id: UUID
            let title: String
            let artist: String
            let albumTitle: String?
            let durationSeconds: Double
            let youTubeId: String
            let artworkUrl: String?
            let liked: Bool
            let playCount: Int
            let lastPlayedAt: Date?
        }
        struct InboxV: Sendable, Hashable {
            let trackId: UUID
            let title: String
            let artist: String
            let youTubeId: String
            let artworkUrl: String?
            let durationSeconds: Double
        }
        struct HistoryAgg: Sendable {
            var plays: Int = 0
            var listenedMs: Int = 0
            var lastPlayedAt: Date? = nil
            var skipCount: Int = 0
            var completedCount: Int = 0
            var bandCounts: [ListeningContext.TimeBand: Int] = [:]
            var appCounts: [String: Int] = [:]
            var headphonePlays: Int = 0
        }
        let now: Date
        let context: ListeningContext?
        let focusActive: Bool
        let hasCurrentSession: Bool
        let libraryTracks: [TrackV]
        let likedTrackIds: Set<UUID>
        let history: [UUID: HistoryAgg]
        let inboxUnheard: [InboxV]
    }

    private func snapshot() -> SituationalSnapshot {
        let now = Date()
        let context = contextProvider()
        let focusState = focusStateProvider()
        let focusActive = focusState.active
        let hasCurrentSession = focusState.sessionId != nil

        let tracks = library.allTracks()
        let libraryTracks = tracks.map {
            SituationalSnapshot.TrackV(
                id: $0.id, title: $0.title, artist: $0.artist,
                albumTitle: $0.albumTitle, durationSeconds: $0.durationSeconds,
                youTubeId: $0.youTubeId, artworkUrl: $0.artworkUrl,
                liked: $0.liked,
                playCount: $0.playCount, lastPlayedAt: $0.lastPlayedAt)
        }
        let likedIds = Set(library.likedTracks().map(\.id))

        // History aggregation (reads HistoryService.events only).
        var history: [UUID: SituationalSnapshot.HistoryAgg] = [:]
        if let historyService {
            let events = historyService.events(matching: HistoryQuery(limit: 5_000))
            for ev in events {
                var agg = history[ev.trackId] ?? .init()
                agg.plays += 1
                agg.listenedMs += ev.listenedMs
                agg.lastPlayedAt = agg.lastPlayedAt.map { max($0, ev.startedAt) } ?? ev.startedAt
                if ev.outcome == .skipped { agg.skipCount += 1 }
                if ev.outcome == .completed { agg.completedCount += 1 }
                if let ctx = ContextService.decode(ev.contextSummaryJSON) {
                    agg.bandCounts[ctx.timeBand, default: 0] += 1
                    if let app = ctx.frontmostAppBundleId { agg.appCounts[app, default: 0] += 1 }
                    if ctx.isHeadphones == true { agg.headphonePlays += 1 }
                }
                history[ev.trackId] = agg
            }
        }

        // Unplayed inbox items.
        var inboxUnheard: [SituationalSnapshot.InboxV] = []
        if let container = modelContainer ?? inboxService?.container {
            let descriptor = FetchDescriptor<InboxItem>(
                predicate: #Predicate { $0.stateRaw == "unheard" })
            if let items = try? container.mainContext.fetch(descriptor) {
                inboxUnheard = items.prefix(40).map {
                    .init(trackId: $0.trackId, title: $0.trackTitle, artist: $0.artist,
                          youTubeId: $0.youTubeId, artworkUrl: $0.artworkUrl,
                          durationSeconds: $0.durationSeconds)
                }
            }
        }

        return SituationalSnapshot(
            now: now, context: context, focusActive: focusActive,
            hasCurrentSession: hasCurrentSession,
            libraryTracks: libraryTracks, likedTrackIds: likedIds,
            history: history, inboxUnheard: inboxUnheard)
    }

    // MARK: - Resolve ids → TrackSnapshot

    private func resolve(_ planned: [PlannedSection], snapshot: SituationalSnapshot) -> [SituationalSection] {
        let byId = Dictionary(uniqueKeysWithValues: snapshot.libraryTracks.map { ($0.id, $0) })
        return planned.compactMap { section in
            let items = section.itemIds.compactMap { id -> TrackSnapshot? in
                guard let t = byId[id] else {
                    // The inbox item may not exist in the library yet (not accepted). Build a minimal snapshot.
                    if let inbox = snapshot.inboxUnheard.first(where: { $0.trackId == id }) {
                        return TrackSnapshot(
                            id: inbox.trackId, title: inbox.title, artist: inbox.artist,
                            albumTitle: nil, durationSeconds: inbox.durationSeconds,
                            youTubeId: inbox.youTubeId,
                            artworkUrl: inbox.artworkUrl,
                            sampleRate: nil, bitDepth: nil, codec: nil,
                            isLossless: false, liked: false)
                    }
                    return nil
                }
                return TrackSnapshot(
                    id: t.id, title: t.title, artist: t.artist,
                    albumTitle: t.albumTitle, durationSeconds: t.durationSeconds,
                    youTubeId: t.youTubeId, artworkUrl: t.artworkUrl,
                    sampleRate: nil, bitDepth: nil, codec: nil,
                    isLossless: false, liked: t.liked)
            }
            guard !items.isEmpty else { return nil }
            return SituationalSection(id: section.id, title: section.title,
                                      subtitle: section.subtitle, items: items)
        }
    }

    // MARK: - Pure plan

    /// Offline computation result (ids only).
    private struct PlannedSection: Sendable {
        let id: String
        let title: String
        let subtitle: String?
        let itemIds: [UUID]
    }

    /// Pure function: computes situational sections from a snapshot. Thread-agnostic and deterministically testable.
    private nonisolated static func plan(from snap: SituationalSnapshot) -> [PlannedSection] {
        if snap.focusActive {
            return focusSections(from: snap)
        }
        return normalSections(from: snap)
    }

    // MARK: - Scoring weights (constants, deterministic)
    private nonisolated static let wListening: Double = 1.0
    private nonisolated static let wContext: Double = 2.0
    private nonisolated static let wRecency: Double = 1.5
    private nonisolated static let wPlaylist: Double = 0.5
    private nonisolated static let wDiscovery: Double = 0.4
    private nonisolated static let penaltyOverplay: Double = 3.0
    private nonisolated static let penaltySkip: Double = 1.5
    private nonisolated static let sectionCap = 10

    /// Generic scorer: computes a track score against one "target context".
    private nonisolated static func score(_ t: SituationalSnapshot.TrackV,
                                          agg: SituationalSnapshot.HistoryAgg?,
                                          targetBand: ListeningContext.TimeBand?,
                                          targetApp: String?,
                                          targetHeadphones: Bool,
                                          discovery: Bool,
                                          now: Date) -> Double {
        let plays = Double(agg?.plays ?? t.playCount)
        let listenedMs = Double(agg?.listenedMs ?? 0)
        let listening = min(plays, 20.0) * Self.wListening + min(listenedMs / 60_000.0, 60.0) * 0.2

        var contextAff = 0.0
        if let band = targetBand {
            contextAff += Double(agg?.bandCounts[band] ?? 0) * Self.wContext
        }
        if let app = targetApp {
            contextAff += Double(agg?.appCounts[app] ?? 0) * Self.wContext
        }
        if targetHeadphones {
            contextAff += Double(agg?.headphonePlays ?? 0) * Self.wContext * 0.5
        }

        let recency: Double = {
            guard let last = agg?.lastPlayedAt ?? t.lastPlayedAt else { return 0 }
            let days = now.timeIntervalSince(last) / 86_400.0
            // Exponential decay: strong within 7 days, approaching 0 after 30 days.
            return Self.wRecency * max(0, 1.0 - days / 30.0)
        }()

        let playlist = t.liked ? Self.wPlaylist : 0
        let discoveryW = (discovery && plays == 0) ? Self.wDiscovery : 0

        // Overplay penalty: multiple plays within 2 hours reduce the score (avoiding repetition).
        let overplay: Double = {
            guard let last = agg?.lastPlayedAt else { return 0 }
            let hours = now.timeIntervalSince(last) / 3600.0
            if hours < 2.0 { return Self.penaltyOverplay * (2.0 - hours) / 2.0 }
            return 0
        }()
        let skip = Double(agg?.skipCount ?? 0) * Self.penaltySkip

        return listening + contextAff + recency + playlist + discoveryW - overplay - skip
    }

    // MARK: - Normal sections (non-focus)

    private nonisolated static func normalSections(from snap: SituationalSnapshot) -> [PlannedSection] {
        let band = snap.context?.timeBand
        let app = snap.context?.frontmostAppBundleId
        let headphones = snap.context?.isHeadphones == true
        var sections: [PlannedSection] = []

        // (1) Time-band section: the title follows the band.
        if let band {
            let title: String, subtitle: String
            switch band {
            case .morning:   title = tr("Good morning", "早安"); subtitle = tr("Ease into the day", "从容开启一天")
            case .afternoon: title = tr("Afternoon energy", "午后能量"); subtitle = tr("Keep moving", "保持节奏")
            case .evening:   title = tr("Evening unwind", "傍晚放松"); subtitle = tr("Wind down", "慢下来")
            case .lateNight: title = tr("Late-night favorites", "深夜最爱"); subtitle = tr("For the quiet hours", "献给安静的时刻")
            }
            let items = topTracks(from: snap, targetBand: band, targetApp: nil,
                                  targetHeadphones: headphones, discovery: false)
            if !items.isEmpty {
                sections.append(PlannedSection(id: "time-band", title: title, subtitle: subtitle, itemIds: items))
            }
        }

        // (2) App carousel: only when context recorded the foreground app (privacy opt-in).
        if let app {
            let label = appLabel(app)
            let items = topTracks(from: snap, targetBand: nil, targetApp: app,
                                  targetHeadphones: headphones, discovery: false)
            if !items.isEmpty {
                sections.append(PlannedSection(id: "app-rotation",
                                      title: tr("Your \(label) rotation", "你的 \(label) 旋转"),
                                      subtitle: tr("What you play while in \(label)", "你在 \(label) 时常听的"),
                                      itemIds: items))
            }
        }

        // (3) High rotation: recency + listening signals.
        let obsessed = topTracks(from: snap, targetBand: nil, targetApp: nil,
                                 targetHeadphones: false, discovery: false)
        if !obsessed.isEmpty {
            sections.append(PlannedSection(id: "recently-obsessed",
                                  title: tr("In heavy rotation", "循环热播"),
                                  subtitle: tr("Your most-played tracks", "你最常听的歌曲"),
                                  itemIds: obsessed))
        }

        // (4) Rediscover: liked tracks outside the active rotation.
        let rediscover = topTracks(from: snap, filter: { $0.liked },
                                   targetBand: nil, targetApp: nil,
                                   targetHeadphones: false, discovery: false,
                                   staleOnlyDays: 14)
        if !rediscover.isEmpty {
            sections.append(PlannedSection(id: "rediscover",
                                  title: tr("Rediscover", "重温"),
                                  subtitle: tr("Liked songs waiting for another spin", "等待再次播放的收藏歌曲"),
                                  itemIds: rediscover))
        }

        // (5) YouTube library tracks scored against the current context.
        let youTube = topTracks(from: snap,
                                targetBand: band, targetApp: nil,
                                targetHeadphones: headphones, discovery: false)
        if !youTube.isEmpty {
            sections.append(PlannedSection(id: "from-youtube",
                                  title: tr("From your YouTube library", "来自你的 YouTube 资料库"),
                                  subtitle: tr("Your tracks, ranked for now", "你的曲目,按此刻排序"),
                                  itemIds: youTube))
        }

        // (6) Inbox: unplayed items (by recency/added time).
        if !snap.inboxUnheard.isEmpty {
            let ids = snap.inboxUnheard
                .sorted { $0.trackId.uuidString < $1.trackId.uuidString }
                .prefix(sectionCap).map(\.trackId)
            sections.append(PlannedSection(id: "from-inbox",
                                  title: tr("From your Inbox", "来自收件箱"),
                                  subtitle: tr("Saved to check out later", "存起来稍后听"),
                                  itemIds: Array(ids)))
        }

        return sections
    }

    // MARK: - Focus sections (focus-only)

    private nonisolated static func focusSections(from snap: SituationalSnapshot) -> [PlannedSection] {
        var sections: [PlannedSection] = []

        // (1) Continue focusing: recent tracks with low skips and high completions.
        let continueItems = topTracks(from: snap,
                                      targetBand: nil, targetApp: nil,
                                      targetHeadphones: false, discovery: false,
                                      preferLowSkip: true)
        if !continueItems.isEmpty {
            sections.append(PlannedSection(id: "focus-continue",
                                  title: tr("Continue Focus Session", "继续专注会话"),
                                  subtitle: tr("Least-skipped, keep the flow", "最少跳过,保持心流"),
                                  itemIds: continueItems))
        }

        // (2) Low-distraction carousel: high-completion tracks (high completedCount, low skips).
        let lowDist = topTracks(from: snap,
                                targetBand: nil, targetApp: nil,
                                targetHeadphones: false, discovery: false,
                                preferLowSkip: true, requireCompletion: true)
        if !lowDist.isEmpty {
            sections.append(PlannedSection(id: "focus-low-distraction",
                                  title: tr("Low-distraction rotation", "低干扰轮播"),
                                  subtitle: tr("Tracks you finish, not skip", "你会听完而非跳过的曲目"),
                                  itemIds: lowDist))
        }
        return sections
    }

    // MARK: - Sorting helpers

    private nonisolated static func topTracks(
        from snap: SituationalSnapshot,
        filter: ((SituationalSnapshot.TrackV) -> Bool)? = nil,
        targetBand: ListeningContext.TimeBand?,
        targetApp: String?,
        targetHeadphones: Bool,
        discovery: Bool,
        staleOnlyDays: Double? = nil,
        preferLowSkip: Bool = false,
        requireCompletion: Bool = false
    ) -> [UUID] {
        let now = snap.now
        let candidates = snap.libraryTracks.filter { t in
            if let filter, !filter(t) { return false }
            if let days = staleOnlyDays {
                guard let last = snap.history[t.id]?.lastPlayedAt ?? t.lastPlayedAt else {
                    return true // Never played — fits "revisit unplayed"
                }
                return now.timeIntervalSince(last) / 86_400.0 >= days
            }
            if requireCompletion, (snap.history[t.id]?.completedCount ?? 0) == 0 {
                return false
            }
            return true
        }
        return candidates
            .sorted { a, b in
                if preferLowSkip {
                    let sa = Double(snap.history[a.id]?.skipCount ?? 0)
                    let sb = Double(snap.history[b.id]?.skipCount ?? 0)
                    if sa != sb { return sa < sb }
                }
                let sa = score(a, agg: snap.history[a.id], targetBand: targetBand,
                               targetApp: targetApp, targetHeadphones: targetHeadphones,
                               discovery: discovery, now: now)
                let sb = score(b, agg: snap.history[b.id], targetBand: targetBand,
                               targetApp: targetApp, targetHeadphones: targetHeadphones,
                               discovery: discovery, now: now)
                return sa > sb
            }
            .prefix(sectionCap).map(\.id)
    }

    /// Derives a friendly label from a bundle id (no fabrication: takes the last path segment; unknown becomes "this app").
    private nonisolated static func appLabel(_ bundleId: String) -> String {
        let parts = bundleId.split(separator: ".")
        if let last = parts.last, !last.isEmpty {
            return String(last).capitalized
        }
        return tr("this app", "当前应用")
    }
}

/// Situational recommendation section (output): title + subtitle + track snapshots. Sendable.
struct SituationalSection: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let items: [TrackSnapshot]
}
