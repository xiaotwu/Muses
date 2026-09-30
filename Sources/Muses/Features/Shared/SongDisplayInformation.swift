import Foundation

/// Verified song fields may replace publisher-derived display text, never user truth.
struct SongDisplayInformation: Equatable {
    let title: String
    let artist: String
    let album: String

    init(row: CollectionTrackRow, metadata: YTDlpBridge.YTDlpPlaylistEntry? = nil) {
        guard let metadata, metadata.id == row.snapshot.youTubeId else {
            title = row.title
            artist = row.artist
            album = row.album
            return
        }
        title = row.title == metadata.title ? (metadata.track ?? row.title) : row.title
        let publisherDerived = row.snapshot.artist.isEmpty
            || row.snapshot.artist == metadata.uploader
            || row.snapshot.artist == row.collectionOwner
        artist = publisherDerived
            ? (metadata.artist ?? tr("Artist unavailable", "艺人信息暂缺"))
            : row.artist
        album = row.album.isEmpty ? (metadata.album ?? "") : row.album
    }
}
