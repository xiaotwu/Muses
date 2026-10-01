import Foundation
import Observation

/// Shared display enrichment, keyed by exact video identity. It does not
/// rewrite playlist sync truth or user-edited Track fields.
@MainActor
@Observable
final class SongCreditCache {
    static let shared = SongCreditCache()
    private var metadata: [String: YTDlpBridge.YTDlpPlaylistEntry] = [:]
    private var collectionOwners: [String: Set<String>] = [:]

    func recordOwner(_ owner: String, videoID: String) {
        guard !owner.isEmpty, collectionOwners[videoID]?.contains(owner) != true else { return }
        collectionOwners[videoID, default: []].insert(owner)
    }

    func store(_ entry: YTDlpBridge.YTDlpPlaylistEntry) {
        guard metadata[entry.id]?.artist != entry.artist || metadata[entry.id]?.uploader != entry.uploader
            || metadata[entry.id]?.title != entry.title else { return }
        if metadata.count >= 512 { metadata.removeAll() }
        metadata[entry.id] = entry
    }

    func isCollectionOwner(_ name: String, videoID: String) -> Bool {
        collectionOwners[videoID]?.contains(name) == true
    }

    func entry(videoID: String) -> YTDlpBridge.YTDlpPlaylistEntry? { metadata[videoID] }

    func artist(snapshot: TrackSnapshot, owner: String? = nil) -> String {
        let entry = metadata[snapshot.youTubeId]
        let original = snapshot.artist
        let missing = SongDisplayInformation.isMissingCredit(original)
        let ownerDerived = original == owner || collectionOwners[snapshot.youTubeId]?.contains(original) == true
        let publisherDerived = original == entry?.uploader
        if missing || ownerDerived || publisherDerived {
            if let artist = entry?.artist, !SongDisplayInformation.isMissingCredit(artist) { return artist }
            if let publisher = entry?.uploader, !SongDisplayInformation.isMissingCredit(publisher) { return publisher }
            return tr("Artist unavailable", "艺人信息暂缺")
        }
        return original
    }
}
