import Foundation

/// Home 发现流的纯值模型(Final Spec §3 / Phase D3)。
///
/// 设计目标:Home 渲染的 section 标题与内容来自 service/provider,而非视图里硬编码的
/// YouTube Music 区段名。`HomeSection` 本身 `Codable + Sendable + Hashable`,可直接经
/// `SWRCache` 缓存(stale-while-revalidate);视图层在主 actor 把 `AlbumRef` 解析回
/// `Album`(@Model),与 `RecommendationService` 的 id→album 映射模式一致。
///
/// 混合远程发现架构:Home 以外部 YouTube/音乐世界发现为主,用户历史仅作轻度排序信号。
/// 强上下文/历史驱动的个性化放在 New(Phase D5)。

/// YouTube 发现卡片:从 `YTDlpPlaylistEntry` + 缩略图 URL 派生的小型不可变值。
struct YouTubeDiscoveryCard: Codable, Sendable, Identifiable, Hashable {
    /// YouTube video id(稳定主键)。
    let id: String
    let title: String
    let uploader: String?
    /// 秒;不可得则 nil。
    let duration: Double?
    /// `https://i.ytimg.com/vi/{id}/hqdefault.jpg` 形式;不可得则 nil。
    let thumbnailURL: String?

    init(id: String, title: String, uploader: String? = nil,
         duration: Double? = nil, thumbnailURL: String? = nil) {
        self.id = id
        self.title = title
        self.uploader = uploader
        self.duration = duration
        self.thumbnailURL = thumbnailURL
    }

    init(entry: YTDlpBridge.YTDlpPlaylistEntry) {
        self.id = entry.id
        self.title = entry.title
        self.uploader = entry.uploader
        self.duration = entry.duration
        self.thumbnailURL = "https://i.ytimg.com/vi/\(entry.id)/hqdefault.jpg"
    }
}

/// 本地专辑的缓存友好引用(避免在缓存层持有 `Album` @Model)。
/// 视图在主 actor 经 `library.allAlbums()` 字典解析回 `Album`。
struct AlbumRef: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let title: String
    let albumArtist: String
    let artworkHash: String?
    let year: Int?

    init(album: Album) {
        self.id = album.id
        self.title = album.title
        self.albumArtist = album.albumArtist
        self.artworkHash = album.artworkHash
        self.year = album.year
    }

    init(id: UUID, title: String, albumArtist: String,
         artworkHash: String? = nil, year: Int? = nil) {
        self.id = id
        self.title = title
        self.albumArtist = albumArtist
        self.artworkHash = artworkHash
        self.year = year
    }
}

/// 歌单的缓存友好引用(本地 `Playlist` 与 YouTube `YouTubeImport` 共用)。
struct PlaylistRef: Codable, Sendable, Identifiable, Hashable {
    /// 跨类型唯一 id(与 `SidebarPlaylistItem.id` 同前缀约定)。
    let id: String
    let name: String
    let isYouTube: Bool
    let artworkUrl: String?
    /// YouTube 歌单首条视频 id,用于无 artwork 时的缩略图回退。
    let firstYouTubeVideoId: String?
}

/// Home 区段类型。决定视图的渲染方式(轮播 / 网格 / 快选)。
enum HomeSectionKind: String, Codable, Sendable, Hashable {
    case albumCarousel
    case playlistCarousel
    case songGrid
    case quickPicks
    case mixed
    case community
    /// 远程 YouTube 发现轮播(单一来源,区别于混合 `mixed`)。
    case youTubeCarousel
}

/// 单个 section 的加载状态。section 之间相互独立(§17/§18 per-section failure)。
enum SectionStatus: Codable, Sendable, Equatable, Hashable {
    case idle
    case loading
    case loaded
    case failed(String?)
}

/// Home 区段:标题/副标题/类型/条目/状态。整体 Codable+Sendable,可缓存。
struct HomeSection: Codable, Sendable, Identifiable {
    /// 稳定 id(用于 SwiftUI `ForEach` 与缓存 key)。
    let id: String
    let title: String
    let subtitle: String?
    let kind: HomeSectionKind
    let items: [DiscoveryItem]
    var status: SectionStatus

    init(id: String, title: String, subtitle: String? = nil,
         kind: HomeSectionKind, items: [DiscoveryItem],
         status: SectionStatus = .loaded) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.items = items
        self.status = status
    }
}

/// 发现条目:统一本地专辑 / 本地+YouTube 曲目快照 / 歌单 / YouTube 发现卡片。
/// 全部为值类型,`HomeSection` 因此可整体缓存。`TrackSnapshot` 非 Hashable,故本枚举
/// 仅提供 `Identifiable`(ForEach 用)而非 `Hashable`。
enum DiscoveryItem: Codable, Sendable, Identifiable {
    case youTube(YouTubeDiscoveryCard)
    case track(TrackSnapshot)
    case album(AlbumRef)
    case playlist(PlaylistRef)

    var id: String {
        switch self {
        case .youTube(let c):  return "yt:\(c.id)"
        case .track(let t):    return "tr:\(t.id.uuidString)"
        case .album(let a):    return "al:\(a.id.uuidString)"
        case .playlist(let p): return "pl:\(p.id)"
        }
    }
}