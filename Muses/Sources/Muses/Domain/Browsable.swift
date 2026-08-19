import Foundation

/// 非持久化浏览投影的来源。
enum BrowseOrigin: String, Sendable, Equatable, Codable {
    /// 本地资料库(对应 SwiftData `Album`/`Artist` @Model,置信度 1.0)。
    case local
    /// 由 YouTube 导入曲目派生(经 MusicBrainz 确认后才 surfaced;未确认不显示)。
    case youTubeDerived
}

/// 跨数据源的规范化标识(MusicBrainz 主 canonical;其余可选)。
struct CanonicalIDs: Sendable, Equatable, Codable {
    var musicBrainzReleaseGroup: String?
    var musicBrainzArtist: String?
    var wikidata: String?
    var appleMusic: String?
    var youTubeChannel: String?

    static let empty = CanonicalIDs()
}

/// 置信度分级(§1):≥0.90 自动解析 / 0.70–0.89 暂定浏览元数据 / <0.70 不解析。
enum ConfidenceBand: Sendable, Equatable {
    case confirmed   // ≥0.90
    case tentative   // 0.70..<0.90
    case rejected     // <0.70

    static func band(for confidence: Double) -> ConfidenceBand {
        if confidence >= 0.90 { return .confirmed }
        if confidence >= 0.70 { return .tentative }
        return .rejected
    }
}

/// 非持久化可浏览专辑投影:统一 local @Model 与 YouTube-derived。
///
/// `localAlbumID` 非空时为本地专辑(点击路由到既有 `AlbumDetailView`);
/// 为空时为 YouTube-derived(由 `trackSnapshots` 支撑,点击路由到 derived detail)。
/// 派生条目仅在置信度 ≥0.70 时由投影层 surfaced(§1)。
struct BrowsableAlbum: Sendable, Equatable, Identifiable, Codable {
    /// 稳定 id:本地 "local:<uuid>";派生 "ytalbum:<groupingKey>"。
    let id: String
    let origin: BrowseOrigin
    let title: String
    let artistName: String
    let year: Int?
    let trackCount: Int
    /// 远程封面 URL(Cover Art Archive / ytimg / iTunes);本地用 artworkHash。
    let artworkURL: String?
    /// 本地缓存封面 hash(ArtworkCache)。
    let artworkHash: String?
    let canonicalIDs: CanonicalIDs
    /// 0...1;本地恒 1.0;派生经 enrichment 计算。
    let confidence: Double
    /// 本地专辑 @Model id(派生为 nil)。
    let localAlbumID: UUID?
    /// 派生条目的支撑曲目(本地为空,由 @Model 关系解析)。
    let trackSnapshots: [TrackSnapshot]

    var band: ConfidenceBand { ConfidenceBand.band(for: confidence) }
    var isLocal: Bool { origin == .local }

    static func local(id: UUID, title: String, artistName: String, year: Int?,
                      trackCount: Int, artworkHash: String?) -> BrowsableAlbum {
        BrowsableAlbum(id: "local:\(id.uuidString)", origin: .local, title: title,
                      artistName: artistName, year: year, trackCount: trackCount,
                      artworkURL: nil, artworkHash: artworkHash,
                      canonicalIDs: .empty, confidence: 1.0,
                      localAlbumID: id, trackSnapshots: [])
    }
}

/// 非持久化可浏览艺术家投影。
struct BrowsableArtist: Sendable, Equatable, Identifiable, Codable {
    let id: String
    let origin: BrowseOrigin
    let name: String
    let artworkURL: String?
    let artworkHash: String?
    let primaryGenre: String?
    let canonicalIDs: CanonicalIDs
    let confidence: Double
    /// 本地艺术家 @Model id(派生为 nil)。
    let localArtistID: UUID?
    let trackCount: Int
    let albumCount: Int
    let trackSnapshots: [TrackSnapshot]

    var band: ConfidenceBand { ConfidenceBand.band(for: confidence) }
    var isLocal: Bool { origin == .local }

    static func local(id: UUID, name: String, artworkHash: String?,
                      primaryGenre: String?, trackCount: Int, albumCount: Int) -> BrowsableArtist {
        BrowsableArtist(id: "local:\(id.uuidString)", origin: .local, name: name,
                       artworkURL: nil, artworkHash: artworkHash, primaryGenre: primaryGenre,
                       canonicalIDs: .empty, confidence: 1.0, localArtistID: id,
                       trackCount: trackCount, albumCount: albumCount, trackSnapshots: [])
    }
}

/// 一次投影快照(Sendable,可跨 actor;由 off-main 构建供 UI 渲染)。
struct BrowseProjection: Sendable, Equatable {
    let albums: [BrowsableAlbum]
    let artists: [BrowsableArtist]
    /// 尚未富集的派生候选 id(供视图触发后台 enrichment)。
    let pendingAlbumIDs: [String]
    let pendingArtistIDs: [String]

    static let empty = BrowseProjection(albums: [], artists: [], pendingAlbumIDs: [], pendingArtistIDs: [])
}