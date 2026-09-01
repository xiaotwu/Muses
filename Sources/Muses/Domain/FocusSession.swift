import Foundation
import SwiftData

/// Focus session (Final Spec §10.9 Feature 9 — Focus Mode).
///
/// Records the lifecycle of one focus run: start time, planned duration (nil = untimed),
/// end time, the linked playlist / listening session, and status. Used for retrospection
/// only; it never drives playback — `FocusService` holds the live state.
@Model
final class FocusSession {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var plannedDurationMs: Int?
    var endedAt: Date?
    var playlistId: UUID?
    var listeningSessionId: UUID?
    var statusRaw: String

    init(id: UUID = UUID(), startedAt: Date = Date(), plannedDurationMs: Int? = nil,
         endedAt: Date? = nil, playlistId: UUID? = nil, listeningSessionId: UUID? = nil,
         status: FocusStatus = .active) {
        self.id = id
        self.startedAt = startedAt
        self.plannedDurationMs = plannedDurationMs
        self.endedAt = endedAt
        self.playlistId = playlistId
        self.listeningSessionId = listeningSessionId
        self.statusRaw = status.rawValue
    }

    var status: FocusStatus {
        get { FocusStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }
}

/// Focus session status.
enum FocusStatus: String, Codable, Sendable {
    case active       // In progress
    case completed   // Ended normally (timer expired / manual stop)
    case cancelled   // Aborted
}

/// Behavior when the timer expires.
enum FocusExpiration: String, Codable, Sendable, CaseIterable {
    case keepPlaying   // Keep playing (just record the end)
    case pause         // Pause playback
    case notifyOnly    // Notify only; leave playback state unchanged

    var label: String {
        switch self {
        case .keepPlaying: return tr("Keep Playing", "继续播放")
        case .pause:       return tr("Pause", "暂停")
        case .notifyOnly:  return tr("Notify Only", "仅通知")
        }
    }
}