import Foundation

/// Home 发现流的 SWR 缓存(Phase D3)。
///
/// 包装 `SWRCache<[HomeSection]>`:以 `HomeDiscoveryInput` 派生的稳定 key 缓存整个
/// 远程发现区段集合。`get` 立即返回(可能 stale),`isFresh` 判定是否跳过后台刷新。
/// 本地区段(Recently Played/Added/Pinned/All Albums)不进入此缓存——它们由资料库
/// 内存快照即时产出。
@MainActor
final class HomeFeedCache {
    static let `default` = HomeFeedCache()

    private let cache: SWRCache<[HomeSection]>
    /// 新鲜窗口(stale-while-revalidate):30 分钟内跳过 yt-dlp spawn(§21)。
    let freshWindow: TimeInterval

    init(directory: URL? = nil, freshWindow: TimeInterval = 30 * 60) {
        let dir = directory ?? HomeFeedCache.defaultDirectory
        self.cache = SWRCache(directory: dir)
        self.freshWindow = freshWindow
    }

    private static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Muses/home-feed")
    }

    /// key 由 input 的稳定字段拼成,避免 hour 抖动导致频繁失效(只精确到 timeBand)。
    static func key(for input: HomeDiscoveryInput) -> String {
        let top = input.topArtistNames.prefix(3).joined(separator: ",")
        let liked = input.likedArtistNames.prefix(2).joined(separator: ",")
        return "feed|band=\(input.timeBand.rawValue)|top=\(top)|liked=\(liked)"
    }

    func get(for input: HomeDiscoveryInput) -> SWRCache<[HomeSection]>.Cached? {
        cache.get(Self.key(for: input))
    }

    func isFresh(_ cached: SWRCache<[HomeSection]>.Cached) -> Bool {
        cache.isFresh(cached, freshWindow: freshWindow)
    }

    func set(_ sections: [HomeSection], for input: HomeDiscoveryInput, fetchedAt: Date = .init()) {
        cache.set(Self.key(for: input), value: sections, fetchedAt: fetchedAt)
    }

    func invalidate() {
        cache.clearAll()
    }
}