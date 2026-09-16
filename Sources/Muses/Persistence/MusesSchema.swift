import SwiftData

/// Final YouTube-native store. This schema is created only in a new physical
/// store and has no staged-migration dependency on the retired local era.
///
/// Generation 2 removes InboxItem, AutomationRule, and FocusSession.
enum MusesSchema {
    static let generation = 2
    static let version = Schema.Version(generation, 0, 0)

    static let models: [any PersistentModel.Type] = [
        Track.self,
        QueueState.self,
        EQPreset.self,
        YouTubeImport.self,
        YouTubeImportItem.self,
        Playlist.self,
        PlaylistItem.self,
        ListeningEvent.self,
        ListeningSession.self,
        TrackNote.self,
        TrackBookmark.self,
        CatalogRelease.self,
        CatalogArtist.self,
        YouTubePlaylistRevision.self,
        YouTubeSyncOperation.self,
        YouTubeSyncBatch.self,
    ]

    static var current: Schema { Schema(models, version: version) }
}
