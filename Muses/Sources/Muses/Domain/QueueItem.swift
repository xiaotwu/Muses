import Foundation

struct QueueItem: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    let track: TrackSnapshot
    let source: TrackSource
    let queuedAt: Date
    let fromContext: QueueSource
    /// 锁定项:不被自动推荐/广播替换移除(手动移除仍允许)。默认 false。
    var locked: Bool
    /// 所属队列分组 id(Phase 19 QueueGroup)。nil = 未分组。
    var groupId: UUID?
    /// 优先级:数值越大越靠前(Phase 19 插入模式)。nil = 无优先级。
    var priority: Int?
    /// 历史状态标签(Phase 19)。仅在条目进入 `history` 时赋值;在 items/upNext 中恒为 nil。
    /// 旧 QueueState JSON 不含该键时解码为 nil(按 `.played` 兜底)。
    var historyState: QueueHistoryState?

    init(id: UUID = UUID(), track: TrackSnapshot, source: TrackSource,
         queuedAt: Date = .init(), fromContext: QueueSource = .songs,
         locked: Bool = false, groupId: UUID? = nil, priority: Int? = nil,
         historyState: QueueHistoryState? = nil) {
        self.id = id; self.track = track; self.source = source
        self.queuedAt = queuedAt; self.fromContext = fromContext
        self.locked = locked; self.groupId = groupId; self.priority = priority
        self.historyState = historyState
    }

    static func == (lhs: QueueItem, rhs: QueueItem) -> Bool { lhs.id == rhs.id }

    // Backward-compat decoder: locked/groupId/priority/historyState default for old
    // QueueState JSON that predates the fields (encode(to:) stays synthesized).
    private enum CodingKeys: String, CodingKey {
        case id, track, source, queuedAt, fromContext, locked, groupId, priority, historyState
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        track = try c.decode(TrackSnapshot.self, forKey: .track)
        source = try c.decode(TrackSource.self, forKey: .source)
        queuedAt = try c.decode(Date.self, forKey: .queuedAt)
        fromContext = try c.decode(QueueSource.self, forKey: .fromContext)
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        groupId = try c.decodeIfPresent(UUID.self, forKey: .groupId)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority)
        historyState = try c.decodeIfPresent(QueueHistoryState.self, forKey: .historyState)
    }
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
    let bitRate: Int?
    let channels: Int?
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
        self.bitRate = track.bitRate; self.channels = track.channels
        self.codec = track.codec; self.isLossless = track.isLossless
        self.liked = track.liked
        self.lyrics = track.lyrics
        self.replayGain = track.replayGain
    }

    init(id: UUID, title: String, artist: String, albumTitle: String?,
         durationSeconds: Double, filePath: String?, youTubeId: String?,
         artworkHash: String?, artworkUrl: String?,
         sampleRate: Int?, bitDepth: Int?, codec: String?, isLossless: Bool,
         liked: Bool = false, lyrics: String? = nil, replayGain: Double? = nil,
         bitRate: Int? = nil, channels: Int? = nil) {
        self.id = id; self.title = title; self.artist = artist
        self.albumTitle = albumTitle; self.durationSeconds = durationSeconds
        self.filePath = filePath; self.youTubeId = youTubeId
        self.artworkHash = artworkHash; self.artworkUrl = artworkUrl
        self.sampleRate = sampleRate; self.bitDepth = bitDepth
        self.bitRate = bitRate; self.channels = channels
        self.codec = codec; self.isLossless = isLossless
        self.liked = liked
        self.lyrics = lyrics
        self.replayGain = replayGain
    }

    // Custom decoder: `liked`/`bitRate`/`channels` default for backward compat with
    // old QueueState JSON that predates the fields (encode(to:) stays synthesized).
    private enum CodingKeys: String, CodingKey {
        case id, title, artist, albumTitle, durationSeconds, filePath, youTubeId
        case artworkHash, artworkUrl, sampleRate, bitDepth, codec, isLossless, liked
        case lyrics, replayGain, bitRate, channels
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
        bitRate = try c.decodeIfPresent(Int.self, forKey: .bitRate)
        channels = try c.decodeIfPresent(Int.self, forKey: .channels)
        codec = try c.decodeIfPresent(String.self, forKey: .codec)
        isLossless = try c.decode(Bool.self, forKey: .isLossless)
        liked = try c.decodeIfPresent(Bool.self, forKey: .liked) ?? false
        lyrics = try c.decodeIfPresent(String.self, forKey: .lyrics)
        replayGain = try c.decodeIfPresent(Double.self, forKey: .replayGain)
    }
}