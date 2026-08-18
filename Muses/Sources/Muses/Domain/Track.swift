import Foundation
import SwiftData

@Model
final class Track {
    @Attribute(.unique) var id: UUID
    var sourceRaw: String          // TrackSource.rawValue
    var title: String
    var artist: String
    var albumTitle: String?
    var albumArtist: String?
    var durationMs: Int
    var trackNo: Int?
    var discNo: Int?
    var year: Int?
    var genre: String?
    var filePath: String?          // .local
    var youTubeId: String?          // .youtube
    var artworkUrl: String?
    var localArtworkHash: String?
    var lyrics: String?
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
    var fileModificationDate: Date?

    var album: Album?

    /// 指向 Artist 实体(optional;轻量迁移加 nullable 列)。保留 `artist: String` 不删。
    var artistRef: Artist?

    /// 反向关联:若本 Track 由某 `YouTubeImportItem` 懒创建,指向该 item。
    var youTubeImportItem: YouTubeImportItem?
    /// 反向关联:若本 Track 作为某 `YouTubeImport` 的本地附加,指向该 import。
    var youTubeImportLocalAddition: YouTubeImport?

    init(id: UUID = UUID(), source: TrackSource, title: String, artist: String,
         albumTitle: String? = nil, albumArtist: String? = nil, durationMs: Int = 0,
         trackNo: Int? = nil, discNo: Int? = nil, year: Int? = nil, genre: String? = nil,
         filePath: String? = nil, youTubeId: String? = nil, artworkUrl: String? = nil,
         localArtworkHash: String? = nil, lyrics: String? = nil, replayGain: Double? = nil,
         sampleRate: Int? = nil, bitDepth: Int? = nil, codec: String? = nil, isLossless: Bool = false,
         metadataStatus: MetadataStatus = .embedded, availability: TrackAvailability = .available,
         addedAt: Date = .init(), lastPlayedAt: Date? = nil, playCount: Int = 0, liked: Bool = false,
         fileModificationDate: Date? = nil, bitRate: Int? = nil, channels: Int? = nil) {
        self.id = id; self.sourceRaw = source.rawValue
        self.title = title; self.artist = artist
        self.albumTitle = albumTitle; self.albumArtist = albumArtist
        self.durationMs = durationMs; self.trackNo = trackNo; self.discNo = discNo
        self.year = year; self.genre = genre; self.filePath = filePath
        self.youTubeId = youTubeId; self.artworkUrl = artworkUrl
        self.localArtworkHash = localArtworkHash; self.lyrics = lyrics
        self.replayGain = replayGain; self.sampleRate = sampleRate
        self.bitDepth = bitDepth; self.codec = codec; self.isLossless = isLossless
        self.bitRate = bitRate; self.channels = channels
        self.metadataStatusRaw = metadataStatus.rawValue
        self.availabilityRaw = availability.rawValue
        self.addedAt = addedAt; self.lastPlayedAt = lastPlayedAt
        self.playCount = playCount; self.liked = liked
        self.fileModificationDate = fileModificationDate
    }

    var source: TrackSource { TrackSource(rawValue: sourceRaw) ?? .local }
    var metadataStatus: MetadataStatus { MetadataStatus(rawValue: metadataStatusRaw) ?? .embedded }
    var availability: TrackAvailability { TrackAvailability(rawValue: availabilityRaw) ?? .available }
    var durationSeconds: Double { Double(durationMs) / 1000.0 }
}