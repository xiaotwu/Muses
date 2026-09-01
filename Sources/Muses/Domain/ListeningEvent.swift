import Foundation
import SwiftData

/// A single listening event: the full record of one track from playback start until it is
/// completed, skipped, stopped, or interrupted.
///
/// Design notes (Final Spec §6 / §10.3):
/// - **Denormalized** `trackTitle`/`artist`/`albumTitle`: history must stay queryable and
///   displayable after the `Track` is deleted, so there is no required relationship to `Track`.
/// - `listenedMs` is the actual listening time in milliseconds (derived from `state.position`
///   by `PlaybackService` when the event fires).
/// - `completionRatio` = `listenedMs / durationMs` (0..1); nil when the duration is unknown.
/// - `outcomeRaw` maps from the event type: `.trackCompleted`→completed, `.trackSkipped`→skipped,
///   `.trackStopped`→stopped, and displaced events lost (`.trackStarted` overwriting an
///   unterminated event)→interrupted.
/// - `contextSummaryJSON` / `sessionId` are reserved slots, currently always nil.
///
/// Indexes (`@Index` on trackId/startedAt/sessionId) are a reserved performance optimization for
/// 100k+ event queries — a non-user-visible implementation detail. To stay consistent with the
/// autoschema lightweight-migration policy and avoid the `@Index` macro's availability risk across
/// macOS versions, no explicit index is declared yet; they can be added as a separate
/// performance-hardening task once event volume warrants it (a minor implementation change
/// allowed by Final Spec §15).
@Model
final class ListeningEvent {
    @Attribute(.unique) var id: UUID
    var trackId: UUID
    var trackTitle: String
    var artist: String
    var albumTitle: String?
    var startedAt: Date
    var endedAt: Date?
    var listenedMs: Int
    var completionRatio: Double?
    var outcomeRaw: String         // ListeningOutcome.rawValue
    var contextSummaryJSON: String?
    var sessionId: UUID?

    init(id: UUID = UUID(), trackId: UUID, trackTitle: String, artist: String,
         albumTitle: String? = nil, startedAt: Date,
         endedAt: Date? = nil, listenedMs: Int = 0, completionRatio: Double? = nil,
         outcome: ListeningOutcome, contextSummaryJSON: String? = nil,
         sessionId: UUID? = nil) {
        self.id = id
        self.trackId = trackId
        self.trackTitle = trackTitle
        self.artist = artist
        self.albumTitle = albumTitle
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.listenedMs = listenedMs
        self.completionRatio = completionRatio
        self.outcomeRaw = outcome.rawValue
        self.contextSummaryJSON = contextSummaryJSON
        self.sessionId = sessionId
    }

    var outcome: ListeningOutcome { ListeningOutcome(rawValue: outcomeRaw) ?? .interrupted }
}

/// How a listening event ended. `interrupted` means the previous track was overwritten by a
/// new one before terminating normally (a fallback for displaced events; the normal path
/// never produces it).
enum ListeningOutcome: String, Codable, Sendable, CaseIterable {
    case completed   // Played to the end (engine completion callback)
    case skipped     // User skipped before reaching the completion threshold
    case stopped     // Substantially listened but not ended naturally (track change / quit)
    case interrupted // Overwritten before terminating (fallback)
}

/// Filter for listening-history queries (Final Spec §10.3: title/artist/album/date/outcome, etc.).
/// All fields optional; nil means unconstrained. `limit` caps the row count (default 200, so the full history is never loaded at once).
struct HistoryQuery: Sendable {
    var titleContains: String?
    var artistContains: String?
    var albumContains: String?
    var outcome: ListeningOutcome?
    var fromDate: Date?
    var toDate: Date?
    var limit: Int = 200

    init(titleContains: String? = nil, artistContains: String? = nil,
         albumContains: String? = nil,
         outcome: ListeningOutcome? = nil, fromDate: Date? = nil,
         toDate: Date? = nil, limit: Int = 200) {
        self.titleContains = titleContains?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artistContains = artistContains?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.albumContains = albumContains?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.outcome = outcome
        self.fromDate = fromDate
        self.toDate = toDate
        self.limit = max(1, limit)
    }
}

/// Listening recap totals (immutable, displayed by `HistoryView`). `topTracks`/`topArtists` are sorted by count, descending, and truncated.
struct ListeningRecap: Sendable {
    struct TrackTally: Sendable, Identifiable { let id: UUID; let title: String; let artist: String; let plays: Int; let listenedMs: Int }
    struct ArtistTally: Sendable, Identifiable { let id: String; let name: String; let plays: Int; let listenedMs: Int }

    let rangeLabel: String
    let totalListenedMs: Int
    let eventCount: Int
    let completedCount: Int
    let skippedCount: Int
    let uniqueTracks: Int
    let uniqueArtists: Int
    let topTracks: [TrackTally]
    let topArtists: [ArtistTally]
}

struct ListeningHeatmapSlice: Sendable, Equatable, Identifiable {
    var id: UUID { trackId }
    let trackId: UUID
    let title: String
    let artist: String
    let listenedMs: Int
}

struct ListeningTimelineEvent: Sendable, Equatable, Identifiable {
    let id: UUID
    let trackId: UUID
    let title: String
    let artist: String
    let startedAt: Date
    let endedAt: Date?
    let listenedMs: Int
    let outcome: ListeningOutcome
}

struct ListeningHeatmapCell: Sendable, Equatable, Identifiable {
    let id: String
    let rowID: String
    let rowIndex: Int
    let hour: Int
    /// Exact accumulated listening time represented by this cell.
    let totalMs: Int
    /// Fixed-scale display value. For All Time this is the weekday daily
    /// average; for calendar ranges it equals `totalMs`.
    let intensityMs: Int
    let eventCount: Int
    let trackCount: Int
    let artistCount: Int
    let sampleDayCount: Int
    let slices: [ListeningHeatmapSlice]
}

struct ListeningHeatmapRow: Sendable, Equatable, Identifiable {
    let id: String
    let index: Int
    let date: Date?
    let weekday: Int?
    let sampleDayCount: Int
    let cells: [ListeningHeatmapCell]
}

struct ListeningHeatmap: Sendable, Equatable {
    let range: RecapRange
    let calendarIdentifier: Calendar.Identifier
    let timeZoneIdentifier: String
    let rows: [ListeningHeatmapRow]

    var nonzeroCells: [ListeningHeatmapCell] {
        rows.flatMap(\.cells).filter { $0.totalMs > 0 }
    }

    var totalMs: Int { rows.flatMap(\.cells).reduce(0) { $0 + $1.totalMs } }

    var peakCell: ListeningHeatmapCell? {
        nonzeroCells.max {
            if $0.intensityMs != $1.intensityMs { return $0.intensityMs < $1.intensityMs }
            return $0.id > $1.id
        }
    }
}

enum ListeningHeatmapLevel: Int, CaseIterable, Sendable, Equatable, Comparable {
    case none, trace, low, medium, high, peak

    init(milliseconds: Int) {
        switch milliseconds {
        case ...0: self = .none
        case ..<300_000: self = .trace
        case ..<900_000: self = .low
        case ..<1_800_000: self = .medium
        case ..<3_600_000: self = .high
        default: self = .peak
        }
    }

    static func < (lhs: ListeningHeatmapLevel, rhs: ListeningHeatmapLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Immutable history row used by the UI. History remains displayable after the
/// referenced library track has been removed.
struct ListeningEventSnapshot: Sendable, Equatable, Identifiable {
    let id: UUID
    let trackId: UUID
    let title: String
    let artist: String
    let albumTitle: String?
    let startedAt: Date
    let listenedMs: Int
    let outcome: ListeningOutcome
}

/// One consistent read for the History screen. Fetch failures are thrown, so a
/// persistence error can never be presented as a legitimate empty library.
struct ListeningHistoryDashboard: Sendable, Equatable {
    let recap: ListeningRecap
    let heatmap: ListeningHeatmap
    let recent: [ListeningEventSnapshot]
    /// Total persisted activity, independent of the selected recap interval.
    /// This lets the UI distinguish a genuinely empty history from an empty
    /// day/week/month selection.
    let totalEventCount: Int
}

extension ListeningRecap: Equatable {}
extension ListeningRecap.TrackTally: Equatable {}
extension ListeningRecap.ArtistTally: Equatable {}
