import Foundation

/// TTL cache for `yt-dlp` `ytsearch` results: keeps Home from re-spawning yt-dlp
/// processes every time it appears. key = `query|limit`, value = `[YTDlpPlaylistEntry]`.
///
/// Stale-while-revalidate strategy:
///  - `get(query:limit:)` returns the cached value (fresh or stale); the caller
///    decides whether to show it immediately.
///  - `isFresh(...)` checks whether it is inside the fresh window (default 30 min);
///    fresh entries skip the spawn.
///  - `set(...)` writes after a successful spawn.
///
/// This is a discovery-metadata cache, kept separate from playback URL resolution
/// (`StreamURLCache`), so yt-dlp does not become an N-per-process invoker for the
/// dozens of cards on Home.
@MainActor
final class YTDlpSearchCache {
    static let `default` = YTDlpSearchCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("Muses/ytdlp-search", isDirectory: true)
    )

    private let backing: SWRCache<[YTDlpBridge.YTDlpPlaylistEntry]>
    /// Fresh window in seconds: under 30 minutes counts as fresh and is reused
    /// without spawning.
    let freshWindow: TimeInterval

    init(directory: URL, freshWindow: TimeInterval = 30 * 60) {
        self.backing = SWRCache(directory: directory)
        self.freshWindow = freshWindow
    }

    private func key(query: String, limit: Int) -> String { "\(query)|\(limit)" }

    /// Reads the cached value (possibly stale); nil when nothing is cached.
    func get(query: String, limit: Int) -> SWRCache<[YTDlpBridge.YTDlpPlaylistEntry]>.Cached? {
        backing.get(key(query: query, limit: limit))
    }

    /// Whether the cache is fresh (exists and age <= freshWindow).
    func isFresh(query: String, limit: Int) -> Bool {
        guard let cached = get(query: query, limit: limit) else { return false }
        return backing.isFresh(cached, freshWindow: freshWindow)
    }

    /// Writes a successfully spawned result.
    func set(query: String, limit: Int,
             entries: [YTDlpBridge.YTDlpPlaylistEntry],
             fetchedAt: Date = .init()) {
        backing.set(key(query: query, limit: limit), value: entries, fetchedAt: fetchedAt)
    }

    /// Invalidates a query (e.g. on force refresh).
    func invalidate(query: String, limit: Int) {
        backing.invalidate(key(query: query, limit: limit))
    }

    /// Clears everything (for tests).
    func clearAll() { backing.clearAll() }
}