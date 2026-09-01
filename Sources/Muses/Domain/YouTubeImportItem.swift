import Foundation
import SwiftData

/// Read-only item on the YouTube side, owned by a `YouTubeImport`.
///
/// Each item lazily creates a `.youtube` `Track` (the `track` relationship); only at
/// playback time does `YouTubeStreamEngine` call yt-dlp to resolve the actual stream URL.
@Model
final class YouTubeImportItem {
    @Attribute(.unique) var id: UUID
    /// Owning import (cascade: deleting the import deletes the item).
    var import_: YouTubeImport?
    /// YouTube video id.
    var youTubeId: String
    /// YouTube playlistItem resource id. This, not video id, identifies a
    /// duplicate occurrence for delete/reorder operations.
    var playlistItemID: String?
    /// Item title.
    var title: String
    /// Item artist (from the uploader or parsed from the title).
    var artist: String
    /// Duration in milliseconds; 0 means unknown.
    var durationMs: Int
    /// Position within the playlist (starting at 0).
    var order: Int
    /// `available`, `private`, `deleted`, `regionBlocked`, or `unknown`.
    var availabilityRaw: String?

    /// Points to the lazily created `.youtube` Track. The `nullify` delete rule keeps
    /// the Track alive when the item is removed (the user may still reference it in the queue or a playlist).
    @Relationship(deleteRule: .nullify, inverse: \Track.youTubeImportItems)
    var track: Track?

    init(id: UUID = UUID(), youTubeId: String, title: String, artist: String,
         durationMs: Int = 0, order: Int = 0, playlistItemID: String? = nil,
         availability: YouTubePlaylistItemAvailability = .available) {
        self.id = id; self.youTubeId = youTubeId; self.title = title
        self.artist = artist; self.durationMs = durationMs; self.order = order
        self.playlistItemID = playlistItemID
        self.availabilityRaw = availability.rawValue
        self.track = nil
    }

    var availability: YouTubePlaylistItemAvailability {
        get { YouTubePlaylistItemAvailability(rawValue: availabilityRaw ?? "") ?? .unknown }
        set { availabilityRaw = newValue.rawValue }
    }
}
