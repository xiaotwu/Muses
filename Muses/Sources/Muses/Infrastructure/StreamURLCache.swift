import Foundation

/// In-memory cache of resolved YouTube stream URLs, optionally backed by disk.
///
/// yt-dlp produces a signed, time-limited direct URL for each video. Re-resolving
/// is slow and rate-limit-prone, so successful resolutions are cached with a TTL
/// (default 6 hours, matching the typical longevity of YouTube's signed URLs).
/// On 403/expiry the caller invalidates the entry so the next load re-resolves.
///
/// 当 `persistencePath` 非空时(如 `.default` 单例),缓存会落盘到 JSON,
/// 跨启动复用已解析的 URL,避免冷启动后首次播放仍要调用 yt-dlp。
@MainActor
final class StreamURLCache {
    /// Shared singleton used by `YouTubeStreamEngine` and friends.启用磁盘持久化。
    static let `default` = StreamURLCache(
        persistencePath: StreamURLCache.defaultPersistenceURL)

    private static var defaultPersistenceURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Caches/Muses/stream-urls.json")
    }

    private struct Entry: Codable {
        let url: URL
        let expiresAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let defaultTTL: TimeInterval
    private let persistencePath: URL?
    private var didLoadFromDisk = false

    init(defaultTTL: TimeInterval = 6 * 3600, persistencePath: URL? = nil) {
        self.defaultTTL = defaultTTL
        self.persistencePath = persistencePath
    }

    /// 懒加载磁盘缓存(仅在配置了 `persistencePath` 且尚未加载时触发)。
    private func ensureLoadedFromDisk() {
        guard !didLoadFromDisk, let path = persistencePath else { return }
        didLoadFromDisk = true
        guard let data = try? Data(contentsOf: path) else { return }
        struct Persisted: Codable { let entries: [String: Entry] }
        guard let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        // 只保留未过期的条目。
        let now = Date()
        for (id, entry) in decoded.entries where entry.expiresAt > now {
            entries[id] = entry
        }
    }

    /// 把当前内存缓存写入磁盘(仅在配置了 `persistencePath` 时)。
    private func persistToDisk() {
        guard let path = persistencePath else { return }
        struct Persisted: Codable { let entries: [String: Entry] }
        let payload = Persisted(entries: entries)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: path, options: .atomic)
    }

    /// Returns the cached URL for `videoId` if present and unexpired.
    /// Expired entries are evicted on read.
    func get(videoId: String) -> URL? {
        ensureLoadedFromDisk()
        guard let entry = entries[videoId] else { return nil }
        guard entry.expiresAt > Date() else {
            entries.removeValue(forKey: videoId)
            persistToDisk()
            return nil
        }
        return entry.url
    }

    /// Stores `url` for `videoId` with the cache's default TTL (or a custom one).
    func set(videoId: String, url: URL, ttl: TimeInterval? = nil) {
        ensureLoadedFromDisk()
        let effective = ttl ?? defaultTTL
        entries[videoId] = Entry(url: url, expiresAt: Date().addingTimeInterval(effective))
        persistToDisk()
    }

    /// Removes a single entry. Used when a 403 indicates the URL went stale early.
    func invalidate(videoId: String) {
        ensureLoadedFromDisk()
        entries.removeValue(forKey: videoId)
        persistToDisk()
    }

    /// Removes a single entry (alias for `invalidate`).
    func remove(videoId: String) {
        invalidate(videoId: videoId)
    }

    /// Evicts every entry whose TTL has passed.
    func clearExpired() {
        ensureLoadedFromDisk()
        let now = Date()
        entries = entries.filter { _, entry in entry.expiresAt > now }
        persistToDisk()
    }
}