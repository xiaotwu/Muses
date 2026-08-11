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

    init(id: UUID = UUID(), title: String, albumArtist: String, year: Int? = nil,
         artworkUrl: String? = nil, artworkHash: String? = nil, isVarious: Bool = false) {
        self.id = id; self.title = title; self.albumArtist = albumArtist
        self.year = year; self.artworkUrl = artworkUrl
        self.artworkHash = artworkHash; self.isVarious = isVarious
        self.tracks = []
    }
}