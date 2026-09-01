import Foundation
import SwiftData

@Model
final class Track {
    @Attribute(.unique) var id: UUID
    var title: String
    var artist: String
    var albumTitle: String?
    var albumArtist: String?
    var durationMs: Int
    var trackNo: Int?
    var discNo: Int?
    var year: Int?
    var genre: String?
    var youTubeId: String
    /// `TrackMediaKind.rawValue`; nil in pre-V3 rows and interpreted as `.song`.
    var mediaKindRaw: String?
    /// Rebuildable YouTube Music catalog links. Stable IDs are never derived
    /// from display text; nil means catalog identity has not been resolved yet.
    var releaseCatalogID: String?
    var releaseOrder: Int?
    var artistCatalogID: String?
    var artworkUrl: String?
    var lyrics: String?
    /// 手动逐曲歌词偏移(毫秒;Phase 22 §10.8)。正值→歌词显示更晚。nil=无手动偏移。
    var lyricsOffsetMs: Int?
    var replayGain: Double?
    var sampleRate: Int?
    var bitDepth: Int?
    var codec: String?
    /// 估算比特率(bits/s),来自 AVAssetTrack.estimatedDataRate。压缩格式才有意义。
    var bitRate: Int?
    /// 声道数,来自 AudioStreamBasicDescription.mChannelsPerFrame。
    var channels: Int?
    var isLossless: Bool
    var metadataStatusRaw: String   // MetadataStatus.rawValue
    var availabilityRaw: String     // TrackAvailability.rawValue
    var addedAt: Date
    var lastPlayedAt: Date?
    var playCount: Int
    var liked: Bool
    /// Playlist occurrences referencing this playable YouTube media row.
    /// To-many is required because one video may appear more than once in one
    /// or several playlists while each occurrence keeps its own item identity.
    var youTubeImportItems: [YouTubeImportItem]?
    init(id: UUID = UUID(), title: String, artist: String,
         albumTitle: String? = nil, albumArtist: String? = nil, durationMs: Int = 0,
         trackNo: Int? = nil, discNo: Int? = nil, year: Int? = nil, genre: String? = nil,
         youTubeId: String, artworkUrl: String? = nil,
         lyrics: String? = nil, replayGain: Double? = nil,
         sampleRate: Int? = nil, bitDepth: Int? = nil, codec: String? = nil, isLossless: Bool = false,
         metadataStatus: MetadataStatus = .embedded, availability: TrackAvailability = .available,
         addedAt: Date = .init(), lastPlayedAt: Date? = nil, playCount: Int = 0, liked: Bool = false,
         bitRate: Int? = nil, channels: Int? = nil, mediaKind: TrackMediaKind = .song,
         releaseCatalogID: String? = nil, releaseOrder: Int? = nil,
         artistCatalogID: String? = nil) {
        self.id = id
        self.title = title; self.artist = artist
        self.albumTitle = albumTitle; self.albumArtist = albumArtist
        self.durationMs = durationMs; self.trackNo = trackNo; self.discNo = discNo
        self.year = year; self.genre = genre
        self.youTubeId = youTubeId; self.artworkUrl = artworkUrl
        self.mediaKindRaw = mediaKind.rawValue
        self.releaseCatalogID = releaseCatalogID
        self.releaseOrder = releaseOrder
        self.artistCatalogID = artistCatalogID
        self.lyrics = lyrics
        self.replayGain = replayGain; self.sampleRate = sampleRate
        self.bitDepth = bitDepth; self.codec = codec; self.isLossless = isLossless
        self.bitRate = bitRate; self.channels = channels
        self.metadataStatusRaw = metadataStatus.rawValue
        self.availabilityRaw = availability.rawValue
        self.addedAt = addedAt; self.lastPlayedAt = lastPlayedAt
        self.playCount = playCount; self.liked = liked
    }

    var metadataStatus: MetadataStatus { MetadataStatus(rawValue: metadataStatusRaw) ?? .embedded }
    var availability: TrackAvailability { TrackAvailability(rawValue: availabilityRaw) ?? .available }
    var durationSeconds: Double { Double(durationMs) / 1000.0 }
    var mediaKind: TrackMediaKind {
        get { mediaKindRaw.flatMap(TrackMediaKind.init(rawValue:)) ?? .song }
        set { mediaKindRaw = newValue.rawValue }
    }
}
