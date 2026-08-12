import Foundation

/// In-memory cache of resolved YouTube stream URLs.
///
/// yt-dlp produces a signed, time-limited direct URL for each video. Re-resolving
/// is slow and rate-limit-prone, so successful resolutions are cached with a TTL
/// (default 6 hours, matching the typical longevity of YouTube's signed URLs).
/// On 403/expiry the caller invalidates the entry so the next load re-resolves.
@MainActor
final class StreamURLCache {
    /// Shared singleton used by `YouTubeStreamEngine` and friends.
    static let `default` = StreamURLCache()

    private struct Entry {
        let url: URL
        let expiresAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let defaultTTL: TimeInterval

    init(defaultTTL: TimeInterval = 6 * 3600) {
        self.defaultTTL = defaultTTL
    }

    /// Returns the cached URL for `videoId` if present and unexpired.
    /// Expired entries are evicted on read.
    func get(videoId: String) -> URL? {
        guard let entry = entries[videoId] else { return nil }
        guard entry.expiresAt > Date() else {
            entries.removeValue(forKey: videoId)
            return nil
        }
        return entry.url
    }

    /// Stores `url` for `videoId` with the cache's default TTL (or a custom one).
    func set(videoId: String, url: URL, ttl: TimeInterval? = nil) {
        let effective = ttl ?? defaultTTL
        entries[videoId] = Entry(url: url, expiresAt: Date().addingTimeInterval(effective))
    }

    /// Removes a single entry. Used when a 403 indicates the URL went stale early.
    func invalidate(videoId: String) {
        entries.removeValue(forKey: videoId)
    }

    /// Removes a single entry (alias for `invalidate`).
    func remove(videoId: String) {
        entries.removeValue(forKey: videoId)
    }

    /// Evicts every entry whose TTL has passed.
    func clearExpired() {
        let now = Date()
        entries = entries.filter { _, entry in entry.expiresAt > now }
    }
}