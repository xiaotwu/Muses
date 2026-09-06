import Foundation
import SwiftData
import Observation

/// YouTube search service: wraps `YTDlpBridge.searchYouTube` and creates `.youtube` Tracks.
///
/// Flow: the user types keywords → `search(query:)` returns the result list →
/// `importAsTrack(entry:)` persists a Track and returns its snapshot.
@Observable
@MainActor
final class YouTubeSearchService {
    private let bridge: any YTDlpBridgeProtocol
    private let modelContainer: ModelContainer
    private let log = AppLog.for("YouTubeSearchService")

    init(bridge: any YTDlpBridgeProtocol, modelContainer: ModelContainer) {
        self.bridge = bridge
        self.modelContainer = modelContainer
    }

    /// Searches YouTube for videos matching the query.
    /// - Returns: the matching entries (title/channel/duration/videoId).
    func fetchPlaylist(url: String) async throws -> [YTDlpBridge.YTDlpPlaylistEntry] {
        try await bridge.fetchPlaylist(url: url, timeout: 60)
    }

    func search(query: String, limit: Int = 10) async throws -> [YTDlpBridge.YTDlpPlaylistEntry] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        do {
            return try await bridge.searchYouTube(query: query, limit: limit, timeout: 30)
        } catch {
            log.error("searchYouTube failed: \(error.localizedDescription)")
            throw YouTubeImportError.networkError(error.localizedDescription)
        }
    }

    /// Imports a search result as a `.youtube` Track (returns the existing track when one with the same youTubeId is already stored).
    /// - Returns: a TrackSnapshot of the created or existing Track, ready for playback.
    @discardableResult
    func importAsTrack(entry: YTDlpBridge.YTDlpPlaylistEntry) async throws -> TrackSnapshot {
        let ctx = ModelContext(modelContainer)
        let videoId = entry.id
        let existing = try ctx.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.youTubeId == videoId }
        ))
        let track: Track
        if let existing = existing.first {
            track = existing
        } else {
            let durationMs = Int((entry.duration ?? 0) * 1000)
            let artist = entry.uploader ?? "Unknown"
            let artistStableID = YouTubeCatalogIdentity.artist(
                channelID: entry.channelID, browseID: nil)
            track = Track(
                title: entry.title,
                artist: artist,
                durationMs: durationMs,
                youTubeId: entry.id,
                artworkUrl: YouTubeThumbnail.urlString(videoId: entry.id),
                mediaKind: entry.inferredMediaKind,
                artistCatalogID: artistStableID
            )
            ctx.insert(track)
            if let artistStableID {
                let key = artistStableID
                let descriptor = FetchDescriptor<CatalogArtist>(
                    predicate: #Predicate { $0.stableID == key })
                if (try? ctx.fetch(descriptor).first) == nil {
                    ctx.insert(CatalogArtist(stableID: artistStableID, name: artist,
                                             channelID: entry.channelID))
                }
            }
            try ctx.save()
            log.info("Imported search result \(entry.id) (\(entry.title))")
        }
        return TrackSnapshot(from: track)
    }
}
