import Foundation
import SwiftData

@Model
final class Album {
    @Attribute(.unique) var id: UUID
    var title: String
    var albumArtist: String
    var year: Int?
    var artworkUrl: String?
    var artworkHash: String?
    var isVarious: Bool

    @Relationship(deleteRule: .nullify, inverse: \Track.album)
    var tracks: [Track]

    /// 指向 Artist 实体(optional;轻量迁移加 nullable 列)。保留 `albumArtist: String` 不删。
    var artistRef: Artist?

    init(id: UUID = UUID(), title: String, albumArtist: String, year: Int? = nil,
         artworkUrl: String? = nil, artworkHash: String? = nil, isVarious: Bool = false) {
        self.id = id; self.title = title; self.albumArtist = albumArtist
        self.year = year; self.artworkUrl = artworkUrl
        self.artworkHash = artworkHash; self.isVarious = isVarious
        self.tracks = []
    }
}