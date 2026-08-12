import Foundation
import SwiftData

/// 艺术家实体:由 `Album.albumArtist` 去重 back-fill 而来(加法方案,不删除原有 String 字段)。
/// 与 Track/Album 的关系为 optional,轻量迁移加 nullable 列即可,无需 VersionedSchema。
@Model
final class Artist {
    @Attribute(.unique) var id: UUID
    var name: String

    /// 丰富化字段(由 MetadataEnricherService.enrichArtist 填充)
    var artworkHash: String?
    var artworkUrl: String?
    var musicBrainzId: String?
    var itunesArtistId: Int?
    var primaryGenre: String?
    var bio: String?

    @Relationship(deleteRule: .nullify, inverse: \Track.artistRef)
    var tracks: [Track]

    @Relationship(deleteRule: .nullify, inverse: \Album.artistRef)
    var albums: [Album]

    init(id: UUID = UUID(), name: String, artworkHash: String? = nil,
         artworkUrl: String? = nil, musicBrainzId: String? = nil,
         itunesArtistId: Int? = nil, primaryGenre: String? = nil, bio: String? = nil) {
        self.id = id; self.name = name
        self.artworkHash = artworkHash; self.artworkUrl = artworkUrl
        self.musicBrainzId = musicBrainzId; self.itunesArtistId = itunesArtistId
        self.primaryGenre = primaryGenre; self.bio = bio
        self.tracks = []; self.albums = []
    }
}