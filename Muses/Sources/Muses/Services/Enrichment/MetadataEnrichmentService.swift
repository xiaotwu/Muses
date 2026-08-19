import Foundation
import Observation
import SwiftData

/// 非持久化元数据富集 + 浏览投影服务(§1)。
///
/// 职责:
/// - 构建统一浏览投影:本地 `Album`/`Artist`(@Model,置信度 1.0)+ YouTube 派生候选
///   (由 `Track.source == .youtube` 的 `albumTitle`/`artist` 分组派生,种子置信度低)。
/// - 对派生候选做 MusicBrainz 确认 + Cover Art Archive 封面,计算置信度;仅 ≥0.70 surfaced。
/// - cache-first SWR:派生候选富集结果入磁盘缓存 + 负缓存,避免重复打 MB。
/// - 失败降级:网络失败/无匹配 → 返回种子(低置信度,不 surfaced);永不阻断播放/浏览。
///
/// 不改 SwiftData schema,不新增 migration。本地 @Model 的元数据富集仍由既有
/// `MetadataEnricherService` 负责(它直接 mutate @Model);本服务只读 @Model,
/// 产出非持久化 `BrowsableAlbum`/`BrowsableArtist` 值类型。
///
/// `@MainActor @Observable`:便于 UI 绑定富集状态;off-main 构建在 `Task.detached`。
@MainActor
@Observable
final class MetadataEnrichmentService {
    private let container: ModelContainer
    private let http: @Sendable (URL) async -> Data?
    private let artworkStore: @Sendable (Data) -> String?
    private let cache: MetadataEnrichmentCache
    private let freshWindow: TimeInterval   // 正缓存新鲜期(默认 6h)
    private let negativeTTL: TimeInterval  // 负缓存有效期(默认 1h)
    private var lastMBRequest: Date = .distantPast
    private let mbUserAgent: String

    /// 已富集的派生条目(id → enriched;含 <0.70 的,投影层按 band 过滤)。
    private(set) var enrichedAlbums: [String: BrowsableAlbum] = [:]
    private(set) var enrichedArtists: [String: BrowsableArtist] = [:]
    private(set) var isEnriching = false
    /// 富集完成计数变更,驱动视图重投影。
    private(set) var enrichmentRevision = 0

    /// 派生候选(种子,off-main 构建);投影层据此 + enriched 内存合成最终列表。
    private var candidateAlbums: [BrowsableAlbum] = []
    private var candidateArtists: [BrowsableArtist] = []

    init(container: ModelContainer,
         cache: MetadataEnrichmentCache = MetadataEnrichmentCache(directory: MetadataEnrichmentService.defaultCacheDirectory),
         http: @escaping @Sendable (URL) async -> Data? = { url in
            await (try? URLSession.shared.data(from: url))?.0
         },
         artworkStore: @escaping @Sendable (Data) -> String? = { data in
            try? ArtworkCache.default.store(data)
         },
         freshWindow: TimeInterval = 6 * 3600,
         negativeTTL: TimeInterval = 3600) {
        self.container = container
        self.cache = cache
        self.http = http
        self.artworkStore = artworkStore
        self.freshWindow = freshWindow
        self.negativeTTL = negativeTTL
        self.mbUserAgent = "Muses/1.0 (https://github.com/muses)"
    }

    static var defaultCacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Muses/enrichment", isDirectory: true)
    }

    // MARK: - Projection

    /// 重建派生候选(off-main 分组)。视图首次出现时调用一次。
    func refreshCandidates() async {
        let container = container
        let (albums, artists) = await Task.detached(priority: .utility) { [container] in
            Self.buildCandidates(container: container)
        }.value
        candidateAlbums = albums
        candidateArtists = artists
    }

    /// 当前投影:本地(每次 off-main 拉取)+ 已富集派生(≥0.70)+ pending 候选 id。
    func projection() async -> BrowseProjection {
        let container = container
        let enrichedAlbums = self.enrichedAlbums
        let enrichedArtists = self.enrichedArtists
        let candidateAlbumIDs = Set(candidateAlbums.map(\.id))
        let candidateArtistIDs = Set(candidateArtists.map(\.id))
        let local = await Task.detached(priority: .utility) { [container] in
            Self.buildLocal(container: container)
        }.value
        // 已富集且 ≥0.70 的派生条目 surfaced。
        let surfacedAlbums = enrichedAlbums.values.filter { $0.band != .rejected && !$0.isLocal }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let surfacedArtists = enrichedArtists.values.filter { $0.band != .rejected && !$0.isLocal }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // pending:候选未富集(内存无)且非负缓存新鲜。
        let pendingAlbums = candidateAlbums.filter { c in
            enrichedAlbums[c.id] == nil && !cache.isNegativeFresh(c.id, ttl: negativeTTL)
        }.map(\.id)
        let pendingArtists = candidateArtists.filter { c in
            enrichedArtists[c.id] == nil && !cache.isNegativeFresh(c.id, ttl: negativeTTL)
        }.map(\.id)
        _ = candidateAlbumIDs; _ = candidateArtistIDs
        return BrowseProjection(
            albums: local.albums + surfacedAlbums,
            artists: local.artists + surfacedArtists,
            pendingAlbumIDs: pendingAlbums,
            pendingArtistIDs: pendingArtists)
    }

    /// 后台富集所有 pending 派生候选;分项失败降级(写负缓存),不抛出。
    func enrichDerived() async {
        guard !isEnriching else { return }
        isEnriching = true
        defer { isEnriching = false; enrichmentRevision &+= 1 }
        for c in candidateAlbums where enrichedAlbums[c.id] == nil
            && !cache.isNegativeFresh(c.id, ttl: negativeTTL) {
            let enriched = await enrich(c)
            storeEnrichedAlbum(enriched)
        }
        for c in candidateArtists where enrichedArtists[c.id] == nil
            && !cache.isNegativeFresh(c.id, ttl: negativeTTL) {
            let enriched = await enrich(c)
            storeEnrichedArtist(enriched)
        }
    }

    // MARK: - Enrich single (MusicBrainz + Cover Art)

    /// 富集单个派生专辑候选。网络失败/无匹配 → 负缓存 + 返回种子(低置信度)。
    func enrich(_ seed: BrowsableAlbum) async -> BrowsableAlbum {
        if let cached = cache.get(seed.id), !cached.isNegative,
           let restored = try? JSONDecoder().decode(BrowsableAlbum.self, from: cached.payload) {
            return restored
        }
        // 负缓存新鲜 → 直接返回种子,避免重复打 MB(SWR 负路径)。
        if cache.isNegativeFresh(seed.id, ttl: negativeTTL) {
            return seed
        }
        let query = seed.artistName.isEmpty
            ? "\"\(seed.title)\""
            : "\"\(seed.title)\" AND artist:\"\(seed.artistName)\""
        let url = EnrichmentEndpoint.musicBrainzReleaseGroup(query: query)
        await waitForMusicBrainzRateLimit()
        guard let data = await http(url),
              let parsed = try? JSONDecoder().decode(MBReleaseGroupSearch.self, from: data),
              let best = Self.bestMatch(for: seed, in: parsed.releaseGroups) else {
            cache.setNegative(seed.id, ttl: negativeTTL)
            return seed  // 保持种子置信度(<0.70 → 不 surfaced)
        }
        // Cover Art Archive 封面(best-effort)。
        var artworkURL = seed.artworkURL
        var artworkHash = seed.artworkHash
        let coverURL = EnrichmentEndpoint.coverArt(releaseId: best.match.id)
        if let imgData = await http(coverURL), let hash = artworkStore(imgData) {
            artworkHash = hash
            artworkURL = coverURL.absoluteString
        }
        let canonical = CanonicalIDs(
            musicBrainzReleaseGroup: best.match.id,
            musicBrainzArtist: best.match.artistCredit.first?.artist?.id,
            wikidata: nil, appleMusic: nil, youTubeChannel: nil)
        let enriched = BrowsableAlbum(
            id: seed.id, origin: seed.origin, title: best.match.title,
            artistName: seed.artistName.isEmpty ? (best.match.primaryArtistName ?? seed.artistName) : seed.artistName,
            year: best.match.year ?? seed.year, trackCount: seed.trackCount,
            artworkURL: artworkURL, artworkHash: artworkHash,
            canonicalIDs: canonical, confidence: best.confidence,
            localAlbumID: nil, trackSnapshots: seed.trackSnapshots)
        if let payload = try? JSONEncoder().encode(enriched) {
            cache.set(payload: payload, for: seed.id)
        }
        return enriched
    }

    /// 富集单个派生艺术家候选(MB artist 搜索;无封面来源则沿用种子)。
    func enrich(_ seed: BrowsableArtist) async -> BrowsableArtist {
        if let cached = cache.get(seed.id), !cached.isNegative,
           let restored = try? JSONDecoder().decode(BrowsableArtist.self, from: cached.payload) {
            return restored
        }
        if cache.isNegativeFresh(seed.id, ttl: negativeTTL) {
            return seed
        }
        let url = EnrichmentEndpoint.musicBrainzArtist(query: "\"\(seed.name)\"")
        await waitForMusicBrainzRateLimit()
        guard let data = await http(url),
              let parsed = try? JSONDecoder().decode(MBArtistSearch.self, from: data),
              let best = Self.bestArtistMatch(for: seed, in: parsed.artists) else {
            cache.setNegative(seed.id, ttl: negativeTTL)
            return seed
        }
        let canonical = CanonicalIDs(
            musicBrainzReleaseGroup: nil, musicBrainzArtist: best.match.id,
            wikidata: nil, appleMusic: nil, youTubeChannel: nil)
        let enriched = BrowsableArtist(
            id: seed.id, origin: seed.origin, name: best.match.name,
            artworkURL: seed.artworkURL, artworkHash: seed.artworkHash,
            primaryGenre: seed.primaryGenre, canonicalIDs: canonical,
            confidence: best.confidence, localArtistID: nil,
            trackCount: seed.trackCount, albumCount: seed.albumCount,
            trackSnapshots: seed.trackSnapshots)
        if let payload = try? JSONEncoder().encode(enriched) {
            cache.set(payload: payload, for: seed.id)
        }
        return enriched
    }

    // MARK: - Internal helpers

    private func storeEnrichedAlbum(_ album: BrowsableAlbum) {
        enrichedAlbums[album.id] = album
    }
    private func storeEnrichedArtist(_ artist: BrowsableArtist) {
        enrichedArtists[artist.id] = artist
    }

    /// MB 1 req/sec 速率限制(沿用既有 MetadataEnricherService 策略)。
    private func waitForMusicBrainzRateLimit() async {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastMBRequest)
        if elapsed < 1.0 {
            try? await Task.sleep(nanoseconds: UInt64((1.0 - elapsed) * 1_000_000_000))
        }
        lastMBRequest = Date()
    }

    // MARK: - Off-main build (pure, on background ModelContext)

    /// 后台构建本地投影(@Model → Sendable)。在 Task.detached 中调用。
    private nonisolated static func buildLocal(container: ModelContainer) -> (albums: [BrowsableAlbum], artists: [BrowsableArtist]) {
        let ctx = ModelContext(container)
        let albums = (try? ctx.fetch(FetchDescriptor<Album>())) ?? []
        let artists = (try? ctx.fetch(FetchDescriptor<Artist>())) ?? []
        let albumItems = albums.map {
            BrowsableAlbum.local(id: $0.id, title: $0.title, artistName: $0.albumArtist,
                                 year: $0.year, trackCount: $0.tracks.count,
                                 artworkHash: $0.artworkHash)
        }
        let artistItems = artists.map {
            BrowsableArtist.local(id: $0.id, name: $0.name, artworkHash: $0.artworkHash,
                                  primaryGenre: $0.primaryGenre,
                                  trackCount: $0.tracks.count, albumCount: $0.albums.count)
        }
        return (albumItems.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending },
                artistItems.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }

    /// 后台构建派生候选(YouTube 曲目分组)。在 Task.detached 中调用。
    private nonisolated static func buildCandidates(container: ModelContainer) -> (albums: [BrowsableAlbum], artists: [BrowsableArtist]) {
        let ctx = ModelContext(container)
        let descriptor = FetchDescriptor<Track>()
        let tracks = (try? ctx.fetch(descriptor)) ?? []
        let ytTracks = tracks.filter { $0.source == .youtube }

        // 派生专辑:按 (albumTitle, albumArtist ?? artist) 分组;仅 albumTitle 非空。
        var albumGroups: [String: [Track]] = [:]
        for t in ytTracks {
            guard let album = t.albumTitle, !album.isEmpty else { continue }
            let key = album + "\u{1F}" + (t.albumArtist ?? t.artist)
            albumGroups[key, default: []].append(t)
        }
        let candidateAlbums: [BrowsableAlbum] = albumGroups.map { key, group in
            let first = group.first!
            let title = first.albumTitle ?? ""
            let artistName = first.albumArtist ?? first.artist
            let snaps = group.map { TrackSnapshot(from: $0) }
            return BrowsableAlbum(
                id: "ytalbum:" + stableHash(key), origin: .youTubeDerived,
                title: title, artistName: artistName, year: first.year,
                trackCount: group.count,
                artworkURL: first.artworkUrl, artworkHash: nil,
                canonicalIDs: .empty, confidence: 0.5,  // 种子(未确认 → 不 surfaced)
                localAlbumID: nil, trackSnapshots: snaps)
        }

        // 派生艺术家:按 artist 分组;仅 artist 非空。种子置信度 0.4(需 MB 确认)。
        var artistGroups: [String: [Track]] = [:]
        for t in ytTracks where !t.artist.isEmpty {
            artistGroups[t.artist, default: []].append(t)
        }
        let candidateArtists: [BrowsableArtist] = artistGroups.map { name, group in
            let snaps = group.map { TrackSnapshot(from: $0) }
            return BrowsableArtist(
                id: "ytartist:" + stableHash(name), origin: .youTubeDerived,
                name: name, artworkURL: group.first?.artworkUrl, artworkHash: nil,
                primaryGenre: nil, canonicalIDs: .empty, confidence: 0.4,
                localArtistID: nil, trackCount: group.count, albumCount: 0,
                trackSnapshots: snaps)
        }
        return (candidateAlbums, candidateArtists)
    }

    /// 稳定短 hash(FNV-1a 32-bit hex),用于派生 id。
    private nonisolated static func stableHash(_ s: String) -> String {
        var hash: UInt32 = 2166136261
        for byte in s.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16777619
        }
        return String(hash, radix: 16)
    }
}

// MARK: - Confidence scoring (pure, testable)

extension MetadataEnrichmentService {
    /// 从 MB 搜索结果中选最佳匹配(置信度 ≥0.70 才算确认;否则返回 nil)。
    nonisolated static func bestMatch(for seed: BrowsableAlbum,
                                       in groups: [MBReleaseGroup]) -> (match: MBReleaseGroup, confidence: Double)? {
        var best: (MBReleaseGroup, Double)?
        for g in groups {
            let c = scoreAlbum(seedTitle: seed.title, seedArtist: seed.artistName,
                               seedYear: seed.year, mb: g)
            if c >= 0.70, best == nil || c > best!.1 {
                best = (g, c)
            }
        }
        return best.map { (match: $0.0, confidence: $0.1) }
    }

    nonisolated static func scoreAlbum(seedTitle: String, seedArtist: String,
                                       seedYear: Int?, mb: MBReleaseGroup) -> Double {
        var s = 0.0
        let t = normalize(seedTitle), mt = normalize(mb.title)
        if !t.isEmpty && t == mt { s += 0.5 }
        else if !t.isEmpty && (mt.contains(t) || t.contains(mt)) { s += 0.25 }
        let a = normalize(seedArtist)
        if !a.isEmpty, let mbArtist = mb.primaryArtistName.map(normalize), !mbArtist.isEmpty {
            if a == mbArtist { s += 0.3 }
            else if mbArtist.contains(a) || a.contains(mbArtist) { s += 0.15 }
        }
        if let seedYear, let mbYear = mb.year, abs(seedYear - mbYear) <= 1 { s += 0.1 }
        if mb.score >= 90 { s += 0.1 }
        return min(s, 1.0)
    }

    nonisolated static func bestArtistMatch(for seed: BrowsableArtist,
                                             in artists: [MBArtist]) -> (match: MBArtist, confidence: Double)? {
        var best: (MBArtist, Double)?
        let n = normalize(seed.name)
        for a in artists {
            let an = normalize(a.name)
            var c = 0.0
            if !n.isEmpty && n == an { c = 0.85 }
            else if !n.isEmpty && (an.contains(n) || n.contains(an)) { c = 0.65 }
            else { c = 0.3 }
            if a.score >= 90 { c += 0.1 }
            c = min(c, 1.0)
            if c >= 0.70, best == nil || c > best!.1 {
                best = (a, c)
            }
        }
        return best.map { (match: $0.0, confidence: $0.1) }
    }

    /// 归一化:小写 + 去标点 + 折叠空白。
    nonisolated static func normalize(_ s: String) -> String {
        s.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            .split(separator: " ")
            .joined(separator: " ")
    }
}

// MARK: - MusicBrainz JSON models (Decodable, Sendable)

struct MBReleaseGroupSearch: Decodable, Sendable {
    let releaseGroups: [MBReleaseGroup]
    enum CodingKeys: String, CodingKey { case releaseGroups = "release-groups" }
}

struct MBReleaseGroup: Decodable, Sendable, Equatable {
    let id: String
    let title: String
    let score: Int
    let firstReleaseDate: String?
    let artistCredit: [MBArtistCredit]
    enum CodingKeys: String, CodingKey {
        case id, title, score
        case firstReleaseDate = "first-release-date"
        case artistCredit = "artist-credit"
    }
    var primaryArtistName: String? { artistCredit.first?.name }
    var year: Int? { firstReleaseDate.flatMap { Int($0.prefix(4)) } }
}

struct MBArtistCredit: Decodable, Sendable, Equatable {
    let name: String?
    let artist: MBArtistRef?
    struct MBArtistRef: Decodable, Sendable, Equatable { let id: String? }
}

struct MBArtistSearch: Decodable, Sendable {
    let artists: [MBArtist]
}

struct MBArtist: Decodable, Sendable, Equatable {
    let id: String
    let name: String
    let score: Int
}