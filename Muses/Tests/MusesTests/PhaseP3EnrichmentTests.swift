import Testing
import Foundation
import SwiftData
@testable import Muses

/// P3a — 非持久化元数据富集投影层 单元测试。
///
/// 覆盖:置信度评分(纯)、MB 响应解析与最佳匹配、投影分组(本地+派生)、缓存 SWR+
/// 负缓存、enrichment 降级。全部用可注入 http stub,不触达真实网络/Keychain。
@MainActor
struct PhaseP3EnrichmentTests {

    /// 线程安全计数器(供 @Sendable http 闭包捕获)。
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var v = 0
        func increment() { lock.lock(); v += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return v }
    }

    // MARK: - Confidence scoring (pure)

    @Test("scoreAlbum: 标题精确+艺术家精确+年份+MB score → 满分")
    func scoreAlbumFull() {
        let mb = mbReleaseGroup(title: "Discovery", artist: "Daft Punk", year: "2001", score: 100)
        let c = MetadataEnrichmentService.scoreAlbum(
            seedTitle: "Discovery", seedArtist: "Daft Punk", seedYear: 2001, mb: mb)
        #expect(c == 1.0) // 0.5+0.3+0.1+0.1
    }

    @Test("scoreAlbum: 标题包含(部分)+艺术家精确 → 0.55;无艺术家 → 不加艺术家分")
    func scoreAlbumPartialTitle() {
        let mb = mbReleaseGroup(title: "Discovery (Deluxe)", artist: "Daft Punk", year: "2001", score: 80)
        let c = MetadataEnrichmentService.scoreAlbum(
            seedTitle: "Discovery", seedArtist: "Daft Punk", seedYear: nil, mb: mb)
        #expect(c == 0.55) // 0.25(包含) + 0.3(艺术家) + 0(MB<90)
    }

    @Test("scoreAlbum: 标题不匹配 → <0.70(被拒)")
    func scoreAlbumNoTitleMatch() {
        let mb = mbReleaseGroup(title: "Homework", artist: "Daft Punk", year: "1997", score: 95)
        let c = MetadataEnrichmentService.scoreAlbum(
            seedTitle: "Discovery", seedArtist: "Daft Punk", seedYear: 2001, mb: mb)
        #expect(c < 0.70) // 0 + 0.3 + 0 + 0.1 = 0.4
        #expect(c == 0.4)
    }

    @Test("normalize: 小写+去标点+折叠空白")
    func normalize() {
        #expect(MetadataEnrichmentService.normalize("Hello,  World!") == "hello world")
        #expect(MetadataEnrichmentService.normalize("Daft-Punk") == "daftpunk")
    }

    // MARK: - bestMatch / bestArtistMatch

    @Test("bestMatch: 多候选选最高置信度;全部 <0.70 返回 nil")
    func bestMatchSelection() {
        let seed = BrowsableAlbum(id: "x", origin: .youTubeDerived, title: "Discovery",
                                  artistName: "Daft Punk", year: 2001, trackCount: 1,
                                  artworkURL: nil, artworkHash: nil, canonicalIDs: .empty,
                                  confidence: 0.5, localAlbumID: nil, trackSnapshots: [])
        let good = mbReleaseGroup(title: "Discovery", artist: "Daft Punk", year: "2001", score: 100)
        let bad = mbReleaseGroup(title: "Homework", artist: "Daft Punk", year: "1997", score: 95)
        let best = MetadataEnrichmentService.bestMatch(for: seed, in: [bad, good])
        #expect(best?.match.id == good.id)
        #expect(best?.confidence == 1.0)

        let none = MetadataEnrichmentService.bestMatch(for: seed, in: [bad])
        #expect(none == nil) // bad 标题不匹配 → 0.4 <0.70
    }

    @Test("bestArtistMatch: 精确名 → ≥0.85;部分名 → 0.65 不达 0.70 阈值")
    func bestArtistMatchThreshold() {
        let seed = BrowsableArtist(id: "x", origin: .youTubeDerived, name: "Daft Punk",
                                   artworkURL: nil, artworkHash: nil, primaryGenre: nil,
                                   canonicalIDs: .empty, confidence: 0.4, localArtistID: nil,
                                   trackCount: 1, albumCount: 0, trackSnapshots: [])
        let exact = MBArtist(id: "mb1", name: "Daft Punk", score: 95)
        let best = MetadataEnrichmentService.bestArtistMatch(for: seed, in: [exact])
        #expect(best != nil)
        #expect(best!.confidence >= 0.85)

        let partial = MBArtist(id: "mb2", name: "Daft Punk Official", score: 60)
        let none = MetadataEnrichmentService.bestArtistMatch(for: seed, in: [partial])
        // "daft punk" contained in "daft punk official" → 0.65 + 0(MB<90) = 0.65 <0.70
        #expect(none == nil)
    }

    // MARK: - Cache (SWR + negative)

    @Test("MetadataEnrichmentCache: 正缓存 set/get + isFresh;负缓存 isNegativeFresh")
    func cachePositiveAndNegative() {
        let cache = MetadataEnrichmentCache.temporary()
        defer { cache.clear() }
        let payload = Data("{}".utf8)
        cache.set(payload: payload, for: "ytalbum:1")
        #expect(cache.get("ytalbum:1")?.payload == payload)
        #expect(cache.isFresh("ytalbum:1", freshWindow: 3600) == true)

        cache.setNegative("ytalbum:2", ttl: 3600)
        #expect(cache.isNegativeFresh("ytalbum:2", ttl: 3600) == true)
        #expect(cache.isNegativeFresh("ytalbum:2", ttl: 0) == false)
        // 未缓存项
        #expect(cache.get("nope") == nil)
        #expect(cache.isNegativeFresh("nope", ttl: 3600) == false)
    }

    @Test("MetadataEnrichmentCache: 负缓存 0 ttl 立即过期")
    func cacheNegativeImmediateExpiry() {
        let cache = MetadataEnrichmentCache.temporary()
        defer { cache.clear() }
        cache.setNegative("x", ttl: 0)
        #expect(cache.isNegativeFresh("x", ttl: 0) == false)
    }

    // MARK: - Enrichment flow (stub http)

    @Test("enrich(album): MB 命中 → 置信度 ≥0.90 + canonical + Cover Art hash;缓存命中第二次不请求")
    func enrichAlbumHit() async throws {
        let cache = MetadataEnrichmentCache.temporary()
        defer { cache.clear() }
        let mbCalled = Counter(), coverCalled = Counter()
        let http: @Sendable (URL) async -> Data? = { url in
            let s = url.absoluteString
            if s.contains("musicbrainz.org") {
                mbCalled.increment()
                let json = #"{"release-groups":[{"id":"rg1","title":"Discovery","score":100,"first-release-date":"2001","artist-credit":[{"name":"Daft Punk","artist":{"id":"art1"}}]}]}"#
                return Data(json.utf8)
            }
            if s.contains("coverartarchive.org") {
                coverCalled.increment()
                return Data([0xFF, 0xD8, 0xFF]) // fake JPEG bytes
            }
            return nil
        }
        let svc = MetadataEnrichmentService(
            container: try makeEmptyContainer(), cache: cache, http: http,
            artworkStore: { _ in "coverhash" }, freshWindow: 3600, negativeTTL: 3600)
        let seed = BrowsableAlbum(id: "ytalbum:k", origin: .youTubeDerived, title: "Discovery",
                                  artistName: "Daft Punk", year: 2001, trackCount: 2,
                                  artworkURL: "https://yt", artworkHash: nil,
                                  canonicalIDs: .empty, confidence: 0.5, localAlbumID: nil,
                                  trackSnapshots: [])
        let e1 = await svc.enrich(seed)
        #expect(e1.confidence == 1.0)
        #expect(e1.canonicalIDs.musicBrainzReleaseGroup == "rg1")
        #expect(e1.canonicalIDs.musicBrainzArtist == "art1")
        #expect(e1.artworkHash == "coverhash")
        #expect(mbCalled.value == 1 && coverCalled.value == 1)
        // 第二次:缓存命中,不再请求网络。
        _ = await svc.enrich(seed)
        #expect(mbCalled.value == 1 && coverCalled.value == 1)
    }

    @Test("enrich(album): MB 无匹配 → 负缓存 + 返回种子(低置信度,不 surfaced)")
    func enrichAlbumNegative() async throws {
        let cache = MetadataEnrichmentCache.temporary()
        defer { cache.clear() }
        let mbCalled = Counter()
        let http: @Sendable (URL) async -> Data? = { _ in
            mbCalled.increment()
            return Data(#"{"release-groups":[]}"#.utf8) // 空结果
        }
        let svc = MetadataEnrichmentService(
            container: try makeEmptyContainer(), cache: cache, http: http,
            artworkStore: { _ in nil }, freshWindow: 3600, negativeTTL: 3600)
        let seed = BrowsableAlbum(id: "ytalbum:k2", origin: .youTubeDerived, title: "Unknown",
                                  artistName: "Uploader", year: nil, trackCount: 1,
                                  artworkURL: nil, artworkHash: nil, canonicalIDs: .empty,
                                  confidence: 0.5, localAlbumID: nil, trackSnapshots: [])
        let e = await svc.enrich(seed)
        #expect(e.confidence == 0.5) // 种子未提升
        #expect(e.band == .rejected)
        // 负缓存:再次调用不应再请求网络(isNegativeFresh 拦截)。
        #expect(cache.isNegativeFresh("ytalbum:k2", ttl: 3600) == true)
        _ = await svc.enrich(seed)
        #expect(mbCalled.value == 1)
    }

    @Test("enrich(album): 网络失败 → 负缓存 + 种子降级")
    func enrichAlbumNetworkFail() async throws {
        let cache = MetadataEnrichmentCache.temporary()
        defer { cache.clear() }
        let http: @Sendable (URL) async -> Data? = { _ in nil }
        let svc = MetadataEnrichmentService(
            container: try makeEmptyContainer(), cache: cache, http: http,
            artworkStore: { _ in nil }, freshWindow: 3600, negativeTTL: 3600)
        let seed = BrowsableAlbum(id: "ytalbum:k3", origin: .youTubeDerived, title: "X",
                                  artistName: "Y", year: nil, trackCount: 1,
                                  artworkURL: nil, artworkHash: nil, canonicalIDs: .empty,
                                  confidence: 0.5, localAlbumID: nil, trackSnapshots: [])
        let e = await svc.enrich(seed)
        #expect(e.confidence == 0.5)
        #expect(e.band == .rejected)
        #expect(cache.isNegativeFresh("ytalbum:k3", ttl: 3600) == true)
    }

    // MARK: - Projection (local + derived surfacing gate)

    @Test("projection: 本地专辑恒 surfaced;派生仅在 enrich 后 ≥0.70 surfaced;pending 列出未富集候选")
    func projectionSurfacingGate() async throws {
        let container = try makeContainerWithTracks()
        let cache = MetadataEnrichmentCache.temporary()
        defer { cache.clear() }
        let svc = MetadataEnrichmentService(
            container: container, cache: cache,
            http: { _ in Data(#"{"release-groups":[]}"#.utf8) },
            artworkStore: { _ in nil }, freshWindow: 3600, negativeTTL: 3600)
        await svc.refreshCandidates()
        let p0 = await svc.projection()
        // 本地专辑/艺术家 surfaced;派生候选未富集 → 不 surfaced,列入 pending。
        #expect(p0.albums.contains { $0.isLocal } == true)
        #expect(p0.artists.contains { $0.isLocal } == true)
        #expect(p0.albums.contains { !$0.isLocal } == false) // 派生未富集
        // 至少有一个派生候选(YouTube 曲目带 albumTitle)进入 pending。
        #expect(p0.pendingAlbumIDs.isEmpty == false)
        // 富集(MB 返回空 → 全部负缓存)后 pending 清空,派生仍不 surfaced。
        await svc.enrichDerived()
        let p1 = await svc.projection()
        #expect(p1.pendingAlbumIDs.isEmpty == true)
        #expect(p1.albums.contains { !$0.isLocal } == false)
    }

    @Test("projection: 派生 MB 命中 ≥0.70 → surfaced,带 YT 来源")
    func projectionDerivedSurfacedOnHit() async throws {
        let container = try makeContainerWithTracks()
        let cache = MetadataEnrichmentCache.temporary()
        defer { cache.clear() }
        let http: @Sendable (URL) async -> Data? = { url in
            if url.absoluteString.contains("musicbrainz.org") {
                let json = #"{"release-groups":[{"id":"rg1","title":"Discovery","score":100,"first-release-date":"2001","artist-credit":[{"name":"Daft Punk","artist":{"id":"art1"}}]}]}"#
                return Data(json.utf8)
            }
            return nil // 无 Cover Art
        }
        let svc = MetadataEnrichmentService(
            container: container, cache: cache, http: http,
            artworkStore: { _ in nil }, freshWindow: 3600, negativeTTL: 3600)
        await svc.refreshCandidates()
        await svc.enrichDerived()
        let p = await svc.projection()
        let derived = p.albums.filter { !$0.isLocal }
        #expect(derived.count == 1)
        #expect(derived.first?.title == "Discovery")
        #expect(derived.first?.band == .confirmed) // 1.0
        #expect(derived.first?.canonicalIDs.musicBrainzReleaseGroup == "rg1")
    }

    // MARK: - Artwork resolution (Browsable → ArtworkSource)

    @Test("ArtworkSource.resolve(album): URL 优先;无 URL 派生回退首支 YT 缩略图;占位")
    func artworkSourceResolution() {
        // 有远程封面 URL → .remote(该 URL)
        let withURL = BrowsableAlbum(id: "x", origin: .local, title: "T", artistName: "A",
                                    year: nil, trackCount: 1, artworkURL: "https://cover.art/x",
                                    artworkHash: nil, canonicalIDs: .empty,
                                    confidence: 1.0, localAlbumID: nil, trackSnapshots: [])
        if case .remote(let url) = ArtworkSource.resolve(for: withURL) {
            #expect(url.absoluteString == "https://cover.art/x")
        } else { Issue.record("有 artworkURL 应解析为 .remote") }

        // 派生无封面 → 回退首支 YT 缩略图
        let derivedNoHash = BrowsableAlbum(id: "y", origin: .youTubeDerived, title: "T",
                                           artistName: "A", year: nil, trackCount: 1,
                                           artworkURL: nil, artworkHash: nil, canonicalIDs: .empty,
                                           confidence: 0.5, localAlbumID: nil,
                                           trackSnapshots: [TrackSnapshot(id: UUID(), title: "s",
                                               artist: "a", albumTitle: nil, durationSeconds: 1,
                                               filePath: nil, youTubeId: "vid1", artworkHash: nil,
                                               artworkUrl: nil, sampleRate: nil, bitDepth: nil,
                                               codec: nil, isLossless: false)])
        if case .remote(let url) = ArtworkSource.resolve(for: derivedNoHash) {
            #expect(url.absoluteString.contains("ytimg.com/vi/vid1"))
        } else { Issue.record("派生无封面应回退 YT 缩略图 .remote") }

        // 本地无任何来源 → .placeholder
        let empty = BrowsableAlbum(id: "z", origin: .local, title: "T", artistName: "A",
                                   year: nil, trackCount: 0, artworkURL: nil, artworkHash: nil,
                                   canonicalIDs: .empty, confidence: 1.0, localAlbumID: nil,
                                   trackSnapshots: [])
        if case .placeholder = ArtworkSource.resolve(for: empty) { /* ok */ } else {
            Issue.record("无任何封面来源应为 .placeholder")
        }

        // 派生且无 YT 曲目 → .placeholder(不回退)
        let derivedEmpty = BrowsableAlbum(id: "w", origin: .youTubeDerived, title: "T",
                                          artistName: "A", year: nil, trackCount: 0,
                                          artworkURL: nil, artworkHash: nil, canonicalIDs: .empty,
                                          confidence: 0.5, localAlbumID: nil, trackSnapshots: [])
        if case .placeholder = ArtworkSource.resolve(for: derivedEmpty) { /* ok */ } else {
            Issue.record("派生无曲目也应为 .placeholder")
        }
    }

    // MARK: - Helpers

    private func mbReleaseGroup(title: String, artist: String, year: String, score: Int) -> MBReleaseGroup {
        let json = #"{"id":"id-\#(title)","title":"\#(title)","score":\#(score),"first-release-date":"\#(year)","artist-credit":[{"name":"\#(artist)","artist":{"id":"art-\#(artist)"}}]}"#
        return try! JSONDecoder().decode(MBReleaseGroup.self, from: Data(json.utf8))
    }

    /// 空 ModelContainer(无数据)。
    private func makeEmptyContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Track.self, Album.self, Artist.self,
                                  YouTubeImport.self, YouTubeImportItem.self,
                                  configurations: config)
    }

    /// 含 1 本地专辑/艺术家 + 1 YouTube 曲目(带 albumTitle)的内存容器。
    private func makeContainerWithTracks() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Track.self, Album.self, Artist.self,
                                           YouTubeImport.self, YouTubeImportItem.self,
                                           configurations: config)
        let ctx = container.mainContext
        let album = Album(title: "Local Album", albumArtist: "Local Artist", year: 2020)
        let localTrack = Track(id: UUID(), source: .local, title: "Local Song",
                               artist: "Local Artist", durationMs: 200_000)
        localTrack.album = album
        let artist = Artist(name: "Local Artist")
        artist.albums.append(album)
        album.artistRef = artist
        let ytTrack = Track(id: UUID(), source: .youtube, title: "One More Time",
                            artist: "Daft Punk", durationMs: 320_000)
        ytTrack.albumTitle = "Discovery"
        ytTrack.albumArtist = "Daft Punk"
        ctx.insert(album); ctx.insert(localTrack); ctx.insert(artist); ctx.insert(ytTrack)
        try ctx.save()
        return container
    }
}