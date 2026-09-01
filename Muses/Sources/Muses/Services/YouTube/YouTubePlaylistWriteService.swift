import Foundation

/// Writes owned YouTube playlist edits back through Data API v3.
/// Liked / system playlists are not writable; callers must check ownership first.
struct YouTubePlaylistWriteService: Sendable {
    let client: YouTubeDataAPIClient

    @discardableResult
    func addVideo(playlistId: String, videoId: String, position: Int? = nil) async throws -> String {
        try await client.insertPlaylistItem(playlistId: playlistId, videoId: videoId, position: position)
    }

    func removeItem(playlistItemID: String) async throws {
        guard !playlistItemID.isEmpty else {
            throw YouTubeDataAPIClient.DataAPIError.parse("missing playlistItem id")
        }
        try await client.deletePlaylistItem(id: playlistItemID)
    }

    func moveItem(playlistItemID: String, playlistId: String,
                  videoId: String, to position: Int) async throws {
        guard !playlistItemID.isEmpty else {
            throw YouTubeDataAPIClient.DataAPIError.parse("missing playlistItem id")
        }
        try await client.updatePlaylistItemPosition(
            id: playlistItemID, playlistId: playlistId, videoId: videoId, position: position)
    }

    /// Compatibility path for older call sites. Duplicate videos are rejected
    /// instead of silently editing the first occurrence.
    func removeVideo(playlistId: String, videoId: String) async throws {
        let items = try await client.playlistItems(playlistId: playlistId)
        let matches = items.filter { $0.videoId == videoId }
        guard matches.count == 1, let item = matches.first,
              !item.playlistItemId.isEmpty else {
            if matches.count > 1 {
                throw YouTubeDataAPIClient.DataAPIError.parse("ambiguous duplicate video; playlistItem id required")
            }
            throw YouTubeDataAPIClient.DataAPIError.parse("playlist item not found")
        }
        try await removeItem(playlistItemID: item.playlistItemId)
    }

    func moveVideo(playlistId: String, videoId: String, to position: Int) async throws {
        let items = try await client.playlistItems(playlistId: playlistId)
        let matches = items.filter { $0.videoId == videoId }
        guard matches.count == 1, let item = matches.first,
              !item.playlistItemId.isEmpty else {
            if matches.count > 1 {
                throw YouTubeDataAPIClient.DataAPIError.parse("ambiguous duplicate video; playlistItem id required")
            }
            throw YouTubeDataAPIClient.DataAPIError.parse("playlist item not found")
        }
        try await moveItem(playlistItemID: item.playlistItemId, playlistId: playlistId,
                           videoId: videoId, to: position)
    }
}
