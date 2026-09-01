import Foundation
import SwiftData

/// Playlist entry: an ordered association between `Playlist` and `Track`.
///
/// The `order` field keeps the entry's position within the playlist (starting at 0).
/// Deleting a Track nullifies `track`; deleting a Playlist cascades to its entries.
@Model
final class PlaylistItem {
    @Attribute(.unique) var id: UUID
    var order: Int
    var playlist: Playlist?
    var track: Track?

    init(id: UUID = UUID(), order: Int, playlist: Playlist? = nil, track: Track? = nil) {
        self.id = id
        self.order = order
        self.playlist = playlist
        self.track = track
    }
}