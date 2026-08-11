import Foundation

struct QueueItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let track: TrackSnapshot
    let source: TrackSource
    let queuedAt: Date
    let fromContext: QueueSource

    init(id: UUID = UUID(), track: TrackSnapshot, source: TrackSource,
         queuedAt: Date = .init(), fromContext: QueueSource = .songs) {
        self.id = id; self.track = track; self.source = source
        self.queuedAt = queuedAt; self.fromContext = fromContext
    }

    static func == (lhs: QueueItem, rhs: QueueItem) -> Bool { lhs.id == rhs.id }
}

/// 轻量只读快照,避免 UI 直接持有 SwiftData @Model 在队列中跨线程传递。
struct TrackSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let artist: String
    let albumTitle: String?
    let durationSeconds: Double
    let filePath: String?
    let youTubeId: String?
    let artworkHash: String?
    let artworkUrl: String?
    let sampleRate: Int?
    let bitDepth: Int?
    let codec: String?
    let isLossless: Bool

    init(from track: Track) {
        self.id = track.id; self.title = track.title; self.artist = track.artist
        self.albumTitle = track.albumTitle
        self.durationSeconds = track.durationSeconds
        self.filePath = track.filePath; self.youTubeId = track.youTubeId
        self.artworkHash = track.localArtworkHash; self.artworkUrl = track.artworkUrl
        self.sampleRate = track.sampleRate; self.bitDepth = track.bitDepth
        self.codec = track.codec; self.isLossless = track.isLossless
    }
}