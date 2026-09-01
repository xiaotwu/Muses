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

/// 队列历史条目的状态标签(Phase 19 Advanced Queue)。
/// - `played`:自然播完 / 充分收听后用户切走(非 skip)。
/// - `skipped`:用户在阈值(`min(30s, 20% 时长)` )内主动切走。
/// - `removed`:用户从 items / upNext 显式移除。
/// 与 Phase 17 `ListeningEvent.outcome`(completed/skipped/stopped/interrupted)
/// 互补:本标签描述「该曲目如何离开当前队列」,事件描述「一次收听如何结束」。
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
