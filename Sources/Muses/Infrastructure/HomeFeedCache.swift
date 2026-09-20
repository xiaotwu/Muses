import Foundation

/// SWR cache for the Home discovery feed.
///
/// Wraps `SWRCache<HomeSnapshot>` and partitions snapshots by recommendation mode,
/// account scope, and source layer. `get` returns immediately (possibly stale);
/// `isFresh` decides whether to skip the background refresh.
@MainActor
final class HomeFeedCache {
    static let `default` = HomeFeedCache()

    enum Layer: Hashable, Sendable {
        case baseline
        case web

        var directoryName: String {
            switch self {
            case .baseline: "baseline-official-v3"
            case .web: "web"
            }
        }
    }

    private struct Partition: Hashable {
        let mode: HomeRecommendationMode
        let scope: HomeFeedScope
        let layer: Layer
        let language: String
        let region: String
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

    /// The key is built from stable input fields (only timeBand precision, never the hour) so jitter cannot invalidate it frequently.
    static func key(for input: HomeDiscoveryInput,
                    mode: HomeRecommendationMode = .muses) -> String {
        guard mode == .muses else { return "feed" }
        let top = input.topArtistNames.prefix(3).joined(separator: ",")
        let liked = input.likedArtistNames.prefix(2).joined(separator: ",")
        return "feed|band=\(input.timeBand.rawValue)|top=\(top)|liked=\(liked)"
    }

    func get(for input: HomeDiscoveryInput,
             layer: Layer,
             mode: HomeRecommendationMode = .muses,
             now: Date = .init()) -> SWRCache<HomeSnapshot>.Cached? {
        guard layer != .web || input.scope != .guest,
              let cached = cache(for: input, layer: layer, mode: mode).get(Self.key(for: input, mode: mode)),
              cached.value.belongs(to: input.scope),
              snapshot(cached.value, isValidFor: layer) else { return nil }
        if layer == .web,
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
             layer: Layer,
             mode: HomeRecommendationMode = .muses) -> Bool {
        guard snapshot.belongs(to: input.scope),
              self.snapshot(snapshot, isValidFor: layer),
              layer != .web || input.scope != .guest else { return false }
        cache(for: input, layer: layer, mode: mode).set(
            Self.key(for: input, mode: mode), value: snapshot, fetchedAt: snapshot.fetchedAt)
        return true
    }

    func invalidate(scope: HomeFeedScope? = nil,
                    layer: Layer? = nil,
                    mode: HomeRecommendationMode? = nil) {
        let targets = caches.filter { partition, _ in
            (mode == nil || partition.mode == mode)
                &&
            (scope == nil || partition.scope == scope)
                && (layer == nil || partition.layer == layer)
        }
        for cache in targets.values { cache.clearAll() }

        // A privacy deletion must also remove dormant locale partitions that
        // were not opened during this process. Only the exact mode/scope/layer
        // subtree is touched.
        if let scope, let layer, let mode {
            let scopeDirectory = directory
                .appendingPathComponent(mode.cacheNamespace, isDirectory: true)
                .appendingPathComponent(scope.cacheNamespace, isDirectory: true)
            // Remove the pre-locale layout for this exact layer as well. It is
            // never readable by the new cache, but privacy deletion must not
            // strand normalized snapshots from the previous layout.
            try? FileManager.default.removeItem(
                at: scopeDirectory.appendingPathComponent(
                    layer.directoryName, isDirectory: true))
            let locales = (try? FileManager.default.contentsOfDirectory(
                at: scopeDirectory, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            for locale in locales {
                let values = try? locale.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { continue }
                try? FileManager.default.removeItem(
                    at: locale.appendingPathComponent(
                        layer.directoryName, isDirectory: true))
            }
        }
    }

    func directoryURL(for scope: HomeFeedScope,
                      layer: Layer,
                      mode: HomeRecommendationMode = .muses,
                      language: String = L10n.languageCode,
                      region: String = Locale.current.region?.identifier ?? "US") -> URL {
        directory
            .appendingPathComponent(mode.cacheNamespace, isDirectory: true)
            .appendingPathComponent(scope.cacheNamespace, isDirectory: true)
            .appendingPathComponent(localeNamespace(
                language: language, region: region), isDirectory: true)
            .appendingPathComponent(layer.directoryName, isDirectory: true)
    }

    private func cache(for input: HomeDiscoveryInput,
                       layer: Layer,
                       mode: HomeRecommendationMode) -> SWRCache<HomeSnapshot> {
        let partition = Partition(
            mode: mode, scope: input.scope, layer: layer,
            language: input.language, region: input.region)
        if let cache = caches[partition] { return cache }
        let cache = SWRCache<HomeSnapshot>(
            directory: directoryURL(
                for: input.scope, layer: layer, mode: mode,
                language: input.language, region: input.region))
        caches[partition] = cache
        return cache
    }

    private func localeNamespace(language: String, region: String) -> String {
        func safe(_ value: String) -> String {
            String(value.lowercased().map { character in
                character.isLetter || character.isNumber || character == "-"
                    ? character : "_"
            }.prefix(40))
        }
        return safe(language) + "-" + safe(region)
    }

    private func snapshot(_ snapshot: HomeSnapshot, isValidFor layer: Layer) -> Bool {
        switch layer {
        case .baseline:
            return snapshot.sections.allSatisfy { $0.source != .signedInWeb }
        case .web:
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
