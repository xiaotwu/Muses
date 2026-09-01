import Foundation

/// Listening context snapshot (Final Spec §10.2 Feature 2 — Contextual Listening).
///
/// Captured by `ContextService` at playback lifecycle transitions (TrackStarted/Completed/Skipped),
/// encoded as JSON into `ListeningEvent.contextSummaryJSON`, and used for history profile aggregation.
///
/// **Privacy (Final Spec §15 high risk):**
/// - Records only local time (hour/dayOfWeek/isWeekend), an optional frontmost app bundle id,
///   the output device name, and a headphone heuristic.
/// - **Never** records window titles, URLs, documents, keystrokes, clipboard, screen, or file contents.
/// - The frontmost app bundle id is recorded only when `PrefKey.contextTrackActiveApp` is explicitly on;
///   the whole capture is gated by `PrefKey.ffContext` (off by default → `capture()` returns nil).
struct ListeningContext: Codable, Sendable, Equatable {
    /// Local hour (0-23).
    let hour: Int
    /// Day of week (1=Sunday ... 7=Saturday, per the current Calendar).
    let dayOfWeek: Int
    let isWeekend: Bool
    /// Frontmost app bundle id; non-nil only when `contextTrackActiveApp` is on.
    let frontmostAppBundleId: String?
    /// Current output device name (Core Audio, best-effort; nil if unavailable — never fabricated).
    let outputDeviceName: String?
    /// Headphone heuristic (device name contains headphone/airpod/earphone/beats); nil if unavailable.
    let isHeadphones: Bool?

    /// Time-of-day classification used by HistoryService aggregation.
    enum TimeBand: String, Codable, Sendable {
        case morning      // 5..<12
        case afternoon    // 12..<18
        case evening      // 18..<22
        case lateNight    // 0..<5 or 22..<24
    }

    var timeBand: TimeBand {
        switch hour {
        case 5..<12:  return .morning
        case 12..<18: return .afternoon
        case 18..<22: return .evening
        default:      return .lateNight   // 0..<5 and 22..<24
        }
    }
}

/// Aggregated context profile result (Final Spec §10.2: most-played-while-app / late-night /
/// morning / headphone / weekend). Immutable value for UI display.
struct ListeningContextProfile: Sendable, Identifiable {
    let id: String          // Stable profile identifier (e.g. "app:com.apple.Xcode" / "band:lateNight")
    let label: String       // Localized display name
    let playCount: Int
    /// Top tracks among the matching events (descending by play count, truncated).
    let topTracks: [ContextProfileTrack]

    struct ContextProfileTrack: Sendable, Identifiable {
        let id: UUID
        let title: String
        let artist: String
        let plays: Int
    }
}