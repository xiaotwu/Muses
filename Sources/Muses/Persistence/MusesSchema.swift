import SwiftData

/// Final YouTube-native store. This schema is created only in a new physical
/// store and has no staged-migration dependency on the retired local era.
///
/// Generation 2 removes InboxItem, AutomationRule, and FocusSession.
/// Generation 3 adds the durable whole-playlist resource journal and exact-
/// target write approval metadata. Generation 4 adds source-backed Track–
/// Release membership edges while retaining the legacy single release fields
/// as read-only compatibility input for existing stores. Generation 5 adds
/// local podcast follows and per-episode progress without a second player.
/// Generation 6 records source-backed show/episode membership separately from
/// the shared video progress row. Generation 7 preserves the collection order
/// across a shuffled queue's restart.
enum MusesSchema {
    static let generation = 7
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
        CatalogTrackReleaseMembership.self,
        YouTubePlaylistRevision.self,
        YouTubeSyncOperation.self,
        YouTubeSyncBatch.self,
        YouTubePlaylistResourceOperation.self,
        PodcastShow.self,
        PodcastEpisodeState.self,
        PodcastEpisodeMembership.self,
    ]

    static var current: Schema { Schema(models, version: version) }
}
