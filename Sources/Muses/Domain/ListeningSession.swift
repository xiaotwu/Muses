import Foundation
import SwiftData

/// One listening session: the continuous stretch of playback from the first play until an
/// explicit stop, prolonged idle, or queue exhaustion.
///
/// Design notes (Final Spec §6 / §10.5):
/// - 1:N with `ListeningEvent` (`ListeningEvent.sessionId` points back to this row's `id`).
///   A session is the time span; an event is the per-track record — the two complement each
///   other for retrospection and restore.
/// - `queueSnapshotJSON` is a self-contained snapshot of the queue at session start (and on
///   track changes), kept for review/audit; the slots actually used for crash/startup recovery
///   are `currentTrackId` / `lastPositionMs` on the single `QueueState` row (written by
///   `SessionService` at each checkpoint). This row's `currentTrackId` / `currentPositionMs`
///   are the session-side copy of the same checkpoint.
/// - `statusRaw`: `active` = in progress (can be picked up by the next launch's restore
///   dialog); `ended` = closed (explicit stop, queue exhaustion, more than 2h idle, or the
///   user choosing "start over").
/// - `contextSummaryJSON` is reserved for Contextual Listening; it is always nil for now.
///
/// Like `ListeningEvent`, no explicit `@Index` is declared yet, keeping autoschema's
/// lightweight migration strategy; indexes can be added once session volume warrants it
/// (a minor implementation change allowed by Final Spec §15).
@Model
final class ListeningSession {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var updatedAt: Date
    var endedAt: Date?
    var statusRaw: String            // SessionStatus.rawValue
    var queueSnapshotJSON: String?
    var currentTrackId: UUID?
    var currentPositionMs: Double?
    var contextSummaryJSON: String?

    init(id: UUID = UUID(), startedAt: Date = .init(), updatedAt: Date? = nil,
         endedAt: Date? = nil, status: SessionStatus = .active,
         queueSnapshotJSON: String? = nil, currentTrackId: UUID? = nil,
         currentPositionMs: Double? = nil, contextSummaryJSON: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.updatedAt = updatedAt ?? startedAt
        self.endedAt = endedAt
        self.statusRaw = status.rawValue
        self.queueSnapshotJSON = queueSnapshotJSON
        self.currentTrackId = currentTrackId
        self.currentPositionMs = currentPositionMs
        self.contextSummaryJSON = contextSummaryJSON
    }

    var status: SessionStatus { SessionStatus(rawValue: statusRaw) ?? .active }
}

/// Session status. `active` can be picked up by the next launch's restore dialog; `ended` is for review queries only.
enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case active
    case ended
}