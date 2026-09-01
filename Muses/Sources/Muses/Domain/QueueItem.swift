import Foundation

struct QueueItem: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    let track: TrackSnapshot
    let queuedAt: Date
    let fromContext: QueueSource
    /// 锁定项:不被自动推荐/广播替换移除(手动移除仍允许)。默认 false。
    var locked: Bool
    /// 所属队列分组 id(Phase 19 QueueGroup)。nil = 未分组。
    var groupId: UUID?
    /// 优先级:数值越大越靠前(Phase 19 插入模式)。nil = 无优先级。
    var priority: Int?
    /// 历史状态标签(Phase 19)。仅在条目进入 `history` 时赋值;在 items/upNext 中恒为 nil。
    var historyState: QueueHistoryState?

    init(id: UUID = UUID(), track: TrackSnapshot,
         queuedAt: Date = .init(), fromContext: QueueSource = .songs,
         locked: Bool = false, groupId: UUID? = nil, priority: Int? = nil,
         historyState: QueueHistoryState? = nil) {
        self.id = id; self.track = track
        self.queuedAt = queuedAt; self.fromContext = fromContext
        self.locked = locked; self.groupId = groupId; self.priority = priority
        self.historyState = historyState
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
    let youTubeId: String
    let artworkUrl: String?
    let sampleRate: Int?
    let bitDepth: Int?
    let bitRate: Int?
    let channels: Int?
    let codec: String?
    let isLossless: Bool
    let liked: Bool
    let lyrics: String?
    let lyricsOffsetMs: Int?
    let replayGain: Double?

    init(from track: Track) {
        self.id = track.id; self.title = track.title; self.artist = track.artist
        self.albumTitle = track.albumTitle
        self.durationSeconds = track.durationSeconds
        self.youTubeId = track.youTubeId
        self.artworkUrl = track.artworkUrl
        self.sampleRate = track.sampleRate; self.bitDepth = track.bitDepth
        self.bitRate = track.bitRate; self.channels = track.channels
        self.codec = track.codec; self.isLossless = track.isLossless
        self.liked = track.liked
        self.lyrics = track.lyrics
        self.lyricsOffsetMs = track.lyricsOffsetMs
        self.replayGain = track.replayGain
    }

    init(id: UUID, title: String, artist: String, albumTitle: String?,
         durationSeconds: Double, youTubeId: String,
         artworkUrl: String?,
         sampleRate: Int?, bitDepth: Int?, codec: String?, isLossless: Bool,
         liked: Bool = false, lyrics: String? = nil, replayGain: Double? = nil,
         bitRate: Int? = nil, channels: Int? = nil, lyricsOffsetMs: Int? = nil) {
        self.id = id; self.title = title; self.artist = artist
        self.albumTitle = albumTitle; self.durationSeconds = durationSeconds
        self.youTubeId = youTubeId
        self.artworkUrl = artworkUrl
        self.sampleRate = sampleRate; self.bitDepth = bitDepth
        self.bitRate = bitRate; self.channels = channels
        self.codec = codec; self.isLossless = isLossless
        self.liked = liked
        self.lyrics = lyrics
        self.lyricsOffsetMs = lyricsOffsetMs
        self.replayGain = replayGain
    }

    /// Sibling queue for a YouTube result set. The playing snapshot keeps its library id;
    /// other rows are ephemeral `youTubeId` snapshots so Next/Previous has collection context.
    static func playbackContext(
        playing: TrackSnapshot,
        youTubeEntries: [YTDlpBridge.YTDlpPlaylistEntry]
    ) -> [TrackSnapshot] {
        guard !youTubeEntries.isEmpty else { return [playing] }
        let mapped = youTubeEntries.map { entry -> TrackSnapshot in
            if playing.youTubeId == entry.id { return playing }
            return TrackSnapshot(
                id: UUID(),
                title: entry.title,
                artist: entry.uploader ?? "",
                albumTitle: nil,
                durationSeconds: entry.duration ?? 0,
                youTubeId: entry.id,
                artworkUrl: YouTubeThumbnail.urlString(videoId: entry.id),
                sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false
            )
        }
        if mapped.contains(where: { $0.youTubeId == playing.youTubeId }) {
            return mapped
        }
        return [playing] + mapped
    }

}
