import Foundation

enum TrackSource: String, Codable, Sendable {
    case local
    case youtube
}

enum AudioQuality: String, Codable, Sendable {
    case lossy, lossless, hiRes
}

enum RepeatMode: String, Codable, Sendable {
    case off, all, one
}

enum QueueSource: String, Codable, Sendable {
    case album, playlist, `import`, search, songs
}

enum MetadataStatus: String, Codable, Sendable {
    case embedded, enriching, complete, missing
}

enum TrackAvailability: String, Codable, Sendable {
    case available, unavailable
}