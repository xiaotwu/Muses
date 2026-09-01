import Foundation

/// Home 发现流的 SWR 缓存(Phase D3)。
///
/// 包装 `SWRCache<HomeSnapshot>`:以 `HomeDiscoveryInput` 派生的稳定 key 缓存整个
/// 远程发现区段集合。`get` 立即返回(可能 stale),`isFresh` 判定是否跳过后台刷新。
/// 本地区段(Recently Played/Added/Pinned/All Albums)不进入此缓存——它们由资料库
/// 内存快照即时产出。
@MainActor
final class HomeFeedCache {
    static let `default` = HomeFeedCache()

    enum Layer: Hashable, Sendable {
        case baseline
        case webV1

        var directoryName: String {
            switch self {
            case .baseline: "baseline"
            case .webV1: "web-v1"
            }
        }
    }

    private struct Partition: Hashable {
        let scope: HomeFeedScope
        let layer: Layer
    }

    private let directory: URL
    private var caches: [Partition: SWRCache<HomeSnapshot>] = [:]
    nonisolated static let baselineFreshWindow: TimeInterval = 30 * 60
    nonisolated static let webFreshWindow: TimeInterval = 15 * 60
    nonisolated static let webStaleLimit: TimeInterval = 7 * 24 * 60 * 60
    let baselineFreshWindow: TimeInterval
    let webFreshWindow: TimeInterval
    let webStaleLimit: TimeInterval

    init(directory: URL? = nil,
         baselineFreshWindow: TimeInterval = HomeFeedCache.baselineFreshWindow,
         webFreshWindow: TimeInterval = HomeFeedCache.webFreshWindow,
         webStaleLimit: TimeInterval = HomeFeedCache.webStaleLimit) {
        self.directory = directory ?? HomeFeedCache.defaultDirectory
        self.baselineFreshWindow = baselineFreshWindow
        self.webFreshWindow = webFreshWindow
        self.webStaleLimit = webStaleLimit
        invalidateLegacyCombinedFiles()
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

    func get(for input: HomeDiscoveryInput,
             layer: Layer,
             now: Date = .init()) -> SWRCache<HomeSnapshot>.Cached? {
        guard layer != .webV1 || input.scope != .guest,
              let cached = cache(for: input.scope, layer: layer).get(Self.key(for: input)),
              cached.value.belongs(to: input.scope),
              snapshot(cached.value, isValidFor: layer) else { return nil }
        if layer == .webV1,
           now.timeIntervalSince(cached.value.fetchedAt) > webStaleLimit {
            return nil
        }
        return cached
    }

    func isFresh(_ cached: SWRCache<HomeSnapshot>.Cached,
                 layer: Layer,
                 now: Date = .init()) -> Bool {
        let window = layer == .baseline ? baselineFreshWindow : webFreshWindow
        return now.timeIntervalSince(cached.value.fetchedAt) <= window
            && cached.value.expiresAt > now
    }

    @discardableResult
    func set(_ snapshot: HomeSnapshot,
             for input: HomeDiscoveryInput,
             layer: Layer) -> Bool {
        guard snapshot.belongs(to: input.scope),
              self.snapshot(snapshot, isValidFor: layer),
              layer != .webV1 || input.scope != .guest else { return false }
        cache(for: input.scope, layer: layer).set(
            Self.key(for: input), value: snapshot, fetchedAt: snapshot.fetchedAt)
        return true
    }

    func invalidate(scope: HomeFeedScope? = nil, layer: Layer? = nil) {
        let targets = caches.filter { partition, _ in
            (scope == nil || partition.scope == scope)
                && (layer == nil || partition.layer == layer)
        }
        for cache in targets.values { cache.clearAll() }

        // A requested partition may not have been opened in memory yet.
        if let scope, let layer {
            cache(for: scope, layer: layer).clearAll()
        }
    }

    func directoryURL(for scope: HomeFeedScope, layer: Layer) -> URL {
        directory
            .appendingPathComponent(scope.cacheNamespace, isDirectory: true)
            .appendingPathComponent(layer.directoryName, isDirectory: true)
    }

    private func cache(for scope: HomeFeedScope, layer: Layer) -> SWRCache<HomeSnapshot> {
        let partition = Partition(scope: scope, layer: layer)
        if let cache = caches[partition] { return cache }
        let cache = SWRCache<HomeSnapshot>(
            directory: directoryURL(for: scope, layer: layer))
        caches[partition] = cache
        return cache
    }

    private func snapshot(_ snapshot: HomeSnapshot, isValidFor layer: Layer) -> Bool {
        switch layer {
        case .baseline:
            return snapshot.sections.allSatisfy { $0.source != .signedInWeb }
        case .webV1:
            guard case .account(let channelID) = snapshot.scope,
                  !snapshot.sections.isEmpty else { return false }
            return snapshot.sections.allSatisfy {
                $0.source == .signedInWeb
                    && $0.accountChannelID == channelID
                    && $0.schemaVersion > 0
            }
        }
    }

    /// Pre-partition versions wrote combined snapshots as JSON files directly
    /// under `home-feed`. They are rebuildable and cannot be trusted as either
    /// baseline or Web, so delete only those direct child files. Account/layer
    /// subdirectories and unrelated files are never traversed or removed.
    private func invalidateLegacyCombinedFiles() {
        guard directory.path.count > 8,
              let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]) else { return }
        for child in children where child.pathExtension.lowercased() == "json" {
            let values = try? child.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                try? FileManager.default.removeItem(at: child)
            }
        }
    }
}
