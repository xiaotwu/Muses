import Foundation

/// YouTube-backed playable media remains one Track model. The media kind only
/// controls browsing and presentation; queue and playback semantics stay shared.
enum TrackMediaKind: String, Codable, Sendable, CaseIterable {
    case song
    case musicVideo
}

enum AudioQuality: String, Codable, Sendable {
    case lossy, lossless, hiRes
}

enum RepeatMode: String, Codable, Sendable {
    case off, all, one

    /// Off → One (single track) → All (playlist/queue).
    var next: RepeatMode {
        switch self {
        case .off: return .one
        case .one: return .all
        case .all: return .off
        }
    }
}

enum QueueSource: String, Codable, Sendable {
    case album, playlist, `import`, search, songs, artist, recently
}

/// State label for queue history entries (Advanced Queue).
/// - `played`: played to the end, or the user switched away after substantial listening (not a skip).
/// - `skipped`: the user actively switched away within the threshold (`min(30s, 20% of duration)`).
/// - `removed`: the user explicitly removed the item from items / upNext.
/// Complements `ListeningEvent.outcome` (completed/skipped/stopped/interrupted):
/// this label describes how a track left the current queue, while the event describes how a listening session ended.
enum QueueHistoryState: String, Codable, Sendable {
    case played
    case skipped
    case removed
}

enum MetadataStatus: String, Codable, Sendable {
    case embedded, enriching, complete, missing
}

enum TrackAvailability: String, Codable, Sendable {
    case available, unavailable
}
