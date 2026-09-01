import SwiftData

/// Final YouTube-native store. This schema is created only in a new physical
/// store and has no staged-migration dependency on the retired local era.
enum MusesSchema {
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
        InboxItem.self,
        TrackNote.self,
        TrackBookmark.self,
        AutomationRule.self,
        FocusSession.self,
        CatalogRelease.self,
        CatalogArtist.self,
        YouTubePlaylistRevision.self,
        YouTubeSyncOperation.self,
        YouTubeSyncBatch.self,
    ]

    static var current: Schema { Schema(models) }
}
