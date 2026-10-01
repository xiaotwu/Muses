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
        let publisherDerived = Self.isMissingCredit(row.snapshot.artist)
            || row.snapshot.artist == metadata.uploader
            || row.snapshot.artist == row.collectionOwner
        artist = publisherDerived
            ? (Self.nonEmpty(metadata.artist) ?? Self.nonEmpty(metadata.uploader) ?? row.artist)
            : row.artist
        album = row.album.isEmpty ? (metadata.album ?? "") : row.album
    }
    static func isMissingCredit(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || ["unknown", "unknown artist", "artist unavailable", "未知艺人", "未知藝人", "艺人信息暂缺", "藝人資訊暫缺"].contains(normalized)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return isMissingCredit(trimmed) ? nil : trimmed
    }
}
