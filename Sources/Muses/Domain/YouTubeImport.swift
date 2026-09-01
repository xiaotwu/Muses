import Foundation
import SwiftData

/// A single YouTube playlist link import (managed as its own entity).
///
/// Local playlist state for an imported/connected YouTube playlist.
/// Remote changes are represented separately by Base and Remote Shadow
/// revisions; this row is never mutated by an unattended remote check.
@Model
final class YouTubeImport {
    @Attribute(.unique) var id: UUID
    /// YouTube playlist id (e.g. `PLxxxxxxx`), used for re-syncing.
    var playlistId: String
    /// Original import URL.
    var url: String
    /// Playlist title (from the `playlist` field of yt-dlp's flat-playlist output).
    var title: String
    /// Playlist channel / uploader.
    var channel: String
    /// Playlist cover URL (optional).
    var artworkUrl: String?
    /// When the import first happened.
    var importedAt: Date
    /// When the playlist was last re-synced.
    var lastSyncedAt: Date?
    /// Owning YouTube channel. Nil means legacy/public import until reconciled.
    var accountChannelID: String?
    /// Latest time Remote Shadow was checked without applying it locally.
    var remoteCheckedAt: Date?
    /// Accepted common Base revision identifier.
    var baseRevisionID: UUID?
    /// Latest Remote Shadow revision identifier.
    var remoteShadowRevisionID: UUID?
    /// Soft deletion timestamp. Recently Deleted retains the row for 30 days.
    var deletedAt: Date?
    /// Whether the active owner/API identified this playlist as writable.
    var remoteWritable: Bool?

    /// Read-only items on the YouTube side (cascade delete: removing the import removes its items).
    @Relationship(deleteRule: .cascade, inverse: \YouTubeImportItem.import_)
    var items: [YouTubeImportItem]?

    init(id: UUID = UUID(), playlistId: String, url: String, title: String,
         channel: String, artworkUrl: String? = nil,
         importedAt: Date = .init(), lastSyncedAt: Date? = nil,
         accountChannelID: String? = nil) {
        self.id = id; self.playlistId = playlistId; self.url = url
        self.title = title; self.channel = channel; self.artworkUrl = artworkUrl
        self.importedAt = importedAt; self.lastSyncedAt = lastSyncedAt
        self.accountChannelID = accountChannelID
        self.remoteCheckedAt = nil
        self.baseRevisionID = nil
        self.remoteShadowRevisionID = nil
        self.deletedAt = nil
        self.remoteWritable = nil
        self.items = []
    }
}
