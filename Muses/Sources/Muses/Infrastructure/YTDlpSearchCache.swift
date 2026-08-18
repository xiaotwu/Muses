import Foundation

/// `yt-dlp` `ytsearch` 结果的 TTL 缓存(spec §21):避免 Home 每次出现都重新 spawn
/// yt-dlp 进程。key = `query|limit`,值 = `[YTDlpPlaylistEntry]`。
///
/// 策略(stale-while-revalidate):
///  - `get(query:limit:)` 返回缓存(无论新鲜与否),调用方据此决定是否立即展示。
///  - `isFresh(...)` 判定是否在新鲜窗口(默认 30 分钟)内;新鲜则跳过 spawn。
///  - `set(...)` 在 spawn 成功后写入。
///
/// 该缓存是「发现元数据」缓存,与播放 URL 解析(`StreamURLCache`)分离,
/// 确保 yt-dlp 不成为几十张 Home 卡片的 N×进程调用器。
@MainActor
final class YTDlpSearchCache {
    static let `default` = YTDlpSearchCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("Muses/ytdlp-search", isDirectory: true)
    )

    private let backing: SWRCache<[YTDlpBridge.YTDlpPlaylistEntry]>
    /// 新鲜窗口(秒):<30 分钟视为新鲜,直接复用不 spawn。
    let freshWindow: TimeInterval

    init(directory: URL, freshWindow: TimeInterval = 30 * 60) {
        self.backing = SWRCache(directory: directory)
        self.freshWindow = freshWindow
    }

    private func key(query: String, limit: Int) -> String { "\(query)|\(limit)" }

    /// 读取缓存(可能 stale);无缓存返回 nil。
    func get(query: String, limit: Int) -> SWRCache<[YTDlpBridge.YTDlpPlaylistEntry]>.Cached? {
        backing.get(key(query: query, limit: limit))
    }

    /// 缓存是否新鲜(存在且年龄 ≤ freshWindow)。
    func isFresh(query: String, limit: Int) -> Bool {
        guard let cached = get(query: query, limit: limit) else { return false }
        return backing.isFresh(cached, freshWindow: freshWindow)
    }

    /// 写入 spawn 成功的结果。
    func set(query: String, limit: Int,
             entries: [YTDlpBridge.YTDlpPlaylistEntry],
             fetchedAt: Date = .init()) {
        backing.set(key(query: query, limit: limit), value: entries, fetchedAt: fetchedAt)
    }

    /// 使某查询失效(如强制刷新)。
    func invalidate(query: String, limit: Int) {
        backing.invalidate(key(query: query, limit: limit))
    }

    /// 清空全部(测试用)。
    func clearAll() { backing.clearAll() }
}