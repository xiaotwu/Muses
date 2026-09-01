import Foundation
import SwiftData

/// A playlist created manually by the user.
///
/// Relationship: `items` → `PlaylistItem` (cascade; deleting the playlist deletes its entries).
/// `PlaylistItem.track` is nullify (deleting a Track breaks the link but keeps the playlist entry).
@Model
final class Playlist {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var pinned: Bool
    @Relationship(deleteRule: .cascade, inverse: \PlaylistItem.playlist)
    var items: [PlaylistItem]?

    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), pinned: Bool = false) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.pinned = pinned
    }
}