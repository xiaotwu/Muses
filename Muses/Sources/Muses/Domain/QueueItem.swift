import Foundation

struct QueueItem: Identifiable, Equatable, Sendable, Codable {
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
struct TrackSnapshot: Identifiable, Equatable, Sendable, Codable {
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
    let liked: Bool
    let lyrics: String?
    let replayGain: Double?

    init(from track: Track) {
        self.id = track.id; self.title = track.title; self.artist = track.artist
        self.albumTitle = track.albumTitle
        self.durationSeconds = track.durationSeconds
        self.filePath = track.filePath; self.youTubeId = track.youTubeId
        self.artworkHash = track.localArtworkHash; self.artworkUrl = track.artworkUrl
        self.sampleRate = track.sampleRate; self.bitDepth = track.bitDepth
        self.codec = track.codec; self.isLossless = track.isLossless
        self.liked = track.liked
        self.lyrics = track.lyrics
        self.replayGain = track.replayGain
    }

    init(id: UUID, title: String, artist: String, albumTitle: String?,
         durationSeconds: Double, filePath: String?, youTubeId: String?,
         artworkHash: String?, artworkUrl: String?,
         sampleRate: Int?, bitDepth: Int?, codec: String?, isLossless: Bool,
         liked: Bool = false, lyrics: String? = nil, replayGain: Double? = nil) {
        self.id = id; self.title = title; self.artist = artist
        self.albumTitle = albumTitle; self.durationSeconds = durationSeconds
        self.filePath = filePath; self.youTubeId = youTubeId
        self.artworkHash = artworkHash; self.artworkUrl = artworkUrl
        self.sampleRate = sampleRate; self.bitDepth = bitDepth
        self.codec = codec; self.isLossless = isLossless
        self.liked = liked
        self.lyrics = lyrics
        self.replayGain = replayGain
    }

    // Custom decoder: `liked` defaults to false for backward compat with old
    // QueueState JSON that predates the field (encode(to:) stays synthesized).
    private enum CodingKeys: String, CodingKey {
        case id, title, artist, albumTitle, durationSeconds, filePath, youTubeId
        case artworkHash, artworkUrl, sampleRate, bitDepth, codec, isLossless, liked
        case lyrics, replayGain
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decode(String.self, forKey: .artist)
        albumTitle = try c.decodeIfPresent(String.self, forKey: .albumTitle)
        durationSeconds = try c.decode(Double.self, forKey: .durationSeconds)
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath)
        youTubeId = try c.decodeIfPresent(String.self, forKey: .youTubeId)
        artworkHash = try c.decodeIfPresent(String.self, forKey: .artworkHash)
        artworkUrl = try c.decodeIfPresent(String.self, forKey: .artworkUrl)
        sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate)
        bitDepth = try c.decodeIfPresent(Int.self, forKey: .bitDepth)
        codec = try c.decodeIfPresent(String.self, forKey: .codec)
        isLossless = try c.decode(Bool.self, forKey: .isLossless)
        liked = try c.decodeIfPresent(Bool.self, forKey: .liked) ?? false
        lyrics = try c.decodeIfPresent(String.self, forKey: .lyrics)
        replayGain = try c.decodeIfPresent(Double.self, forKey: .replayGain)
    }
}