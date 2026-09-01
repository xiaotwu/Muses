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

enum HomeCardEndpointKind: String, Codable, Sendable, Hashable {
    case video
    case playlist
    case browse
    case channel
}

struct HomeCardEndpoint: Codable, Sendable, Hashable {
    let kind: HomeCardEndpointKind
    let identifier: String
}

enum HomeCardAvailability: String, Codable, Sendable, Hashable {
    case available
    case unavailable
    case regionBlocked
    case privateItem
    case deleted
}

/// YouTube discovery card. Legacy/public cards use a video id directly;
/// normalized Web Home cards additionally preserve their whitelisted browse
/// and play endpoints without retaining any raw response data.
struct YouTubeDiscoveryCard: Codable, Sendable, Identifiable, Hashable {
    /// Stable renderer identity. For legacy cards this is the video id.
    let id: String
    let title: String
    let uploader: String?
    /// 秒;不可得则 nil。
    let duration: Double?
    /// `https://i.ytimg.com/vi/{id}/hqdefault.jpg` 形式;不可得则 nil。
    let thumbnailURL: String?
    let browseEndpoint: HomeCardEndpoint?
    let playEndpoint: HomeCardEndpoint?
    let availability: HomeCardAvailability

    var playableVideoID: String? {
        guard availability == .available else { return nil }
        if let playEndpoint, playEndpoint.kind == .video {
            return playEndpoint.identifier
        }
        // Backward-compatible cache decoding: cards written before endpoint
        // normalization have neither endpoint and their stable id is video id.
        return browseEndpoint == nil ? id : nil
    }

    init(id: String, title: String, uploader: String? = nil,
         duration: Double? = nil, thumbnailURL: String? = nil) {
        self.id = id
        self.title = title
        self.uploader = uploader
        self.duration = duration
        self.thumbnailURL = thumbnailURL
        self.browseEndpoint = nil
        self.playEndpoint = HomeCardEndpoint(kind: .video, identifier: id)
        self.availability = .available
    }

    init(id: String, title: String, uploader: String? = nil,
         duration: Double? = nil, thumbnailURL: String? = nil,
         browseEndpoint: HomeCardEndpoint?, playEndpoint: HomeCardEndpoint?,
         availability: HomeCardAvailability) {
        self.id = id
        self.title = title
        self.uploader = uploader
        self.duration = duration
        self.thumbnailURL = thumbnailURL
        self.browseEndpoint = browseEndpoint
        self.playEndpoint = playEndpoint
        self.availability = availability
    }

    init(entry: YTDlpBridge.YTDlpPlaylistEntry) {
        self.id = entry.id
        self.title = entry.title
        self.uploader = entry.uploader
        self.duration = entry.duration
        self.thumbnailURL = YouTubeThumbnail.urlString(videoId: entry.id)
        self.browseEndpoint = nil
        self.playEndpoint = HomeCardEndpoint(kind: .video, identifier: entry.id)
        self.availability = .available
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, uploader, duration, thumbnailURL
        case browseEndpoint, playEndpoint, availability
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        uploader = try values.decodeIfPresent(String.self, forKey: .uploader)
        duration = try values.decodeIfPresent(Double.self, forKey: .duration)
        thumbnailURL = try values.decodeIfPresent(String.self, forKey: .thumbnailURL)
        browseEndpoint = try values.decodeIfPresent(HomeCardEndpoint.self, forKey: .browseEndpoint)
        playEndpoint = try values.decodeIfPresent(HomeCardEndpoint.self, forKey: .playEndpoint)
        availability = try values.decodeIfPresent(
            HomeCardAvailability.self, forKey: .availability) ?? .available
    }
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

/// The actual capability that produced a Home section. This is product truth,
/// not decorative metadata: account, public, and Web-session content must not
/// silently impersonate one another.
enum HomeSource: String, Codable, Sendable, Hashable {
    case signedInWeb
    case officialAccount
    case publicDiscovery
    case localLibrary
    case cached

    var label: String {
        switch self {
        case .signedInWeb: tr("YouTube Music personalized", "YouTube Music 个性化")
        case .officialAccount: tr("Your YouTube account", "你的 YouTube 账号")
        case .publicDiscovery: tr("Public discovery", "公共发现")
        case .localLibrary: tr("Your library", "你的资料库")
        case .cached: tr("Saved result", "已保存结果")
        }
    }
}

/// Durable cache/API boundary for one complete Home response. Section-level
/// metadata remains available for mixed-source composition, while the snapshot
/// provides one manifest that can be rejected before any cross-account content
/// reaches the UI.
struct HomeSnapshot: Codable, Sendable {
    let scope: HomeFeedScope
    let accountChannelID: String?
    let source: HomeSource
    let schemaVersion: Int
    let fetchedAt: Date
    let expiresAt: Date
    let staleReason: String?
    let sections: [HomeSection]

    init(scope: HomeFeedScope, sections: [HomeSection],
         fetchedAt: Date, expiresAt: Date, staleReason: String? = nil,
         schemaVersion: Int = 1) {
        self.scope = scope
        if case .account(let channelID) = scope {
            self.accountChannelID = channelID
        } else {
            self.accountChannelID = nil
        }
        self.source = Self.primarySource(in: sections)
        self.schemaVersion = schemaVersion
        self.fetchedAt = fetchedAt
        self.expiresAt = expiresAt
        self.staleReason = staleReason
        self.sections = sections
    }

    func belongs(to expectedScope: HomeFeedScope) -> Bool {
        guard scope == expectedScope else { return false }
        switch expectedScope {
        case .guest:
            return accountChannelID == nil
                && sections.allSatisfy { $0.accountChannelID == nil }
        case .account(let channelID):
            return accountChannelID == channelID
                && sections.allSatisfy { section in
                    section.accountChannelID == nil
                        || section.accountChannelID == channelID
                }
        }
    }

    private static func primarySource(in sections: [HomeSection]) -> HomeSource {
        let sources = Set(sections.map(\.source))
        for candidate in [HomeSource.signedInWeb, .officialAccount,
                          .publicDiscovery, .localLibrary, .cached]
            where sources.contains(candidate) {
            return candidate
        }
        return .publicDiscovery
    }
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
    let source: HomeSource
    /// Set only when `source == .cached`, preserving the upstream promise.
    let cachedOrigin: HomeSource?
    let accountChannelID: String?
    let schemaVersion: Int
    let fetchedAt: Date?
    let expiresAt: Date?
    let staleReason: String?

    init(id: String, title: String, subtitle: String? = nil,
         kind: HomeSectionKind, items: [DiscoveryItem],
         status: SectionStatus = .loaded,
         source: HomeSource = .publicDiscovery,
         cachedOrigin: HomeSource? = nil,
         accountChannelID: String? = nil,
         schemaVersion: Int = 1,
         fetchedAt: Date? = .init(),
         expiresAt: Date? = nil,
         staleReason: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.items = items
        self.status = status
        self.source = source
        self.cachedOrigin = cachedOrigin
        self.accountChannelID = accountChannelID
        self.schemaVersion = schemaVersion
        self.fetchedAt = fetchedAt
        self.expiresAt = expiresAt
        self.staleReason = staleReason
    }

    func presentedFromCache(staleReason: String?) -> HomeSection {
        HomeSection(
            id: id, title: title, subtitle: subtitle, kind: kind, items: items,
            status: status, source: .cached,
            cachedOrigin: source == .cached ? cachedOrigin : source,
            accountChannelID: accountChannelID, schemaVersion: schemaVersion,
            fetchedAt: fetchedAt, expiresAt: expiresAt,
            staleReason: staleReason ?? self.staleReason
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, subtitle, kind, items, status, source, cachedOrigin
        case accountChannelID, schemaVersion, fetchedAt, expiresAt, staleReason
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        subtitle = try values.decodeIfPresent(String.self, forKey: .subtitle)
        kind = try values.decode(HomeSectionKind.self, forKey: .kind)
        items = try values.decode([DiscoveryItem].self, forKey: .items)
        status = try values.decode(SectionStatus.self, forKey: .status)
        source = try values.decodeIfPresent(HomeSource.self, forKey: .source)
            ?? .publicDiscovery
        cachedOrigin = try values.decodeIfPresent(HomeSource.self, forKey: .cachedOrigin)
        accountChannelID = try values.decodeIfPresent(String.self, forKey: .accountChannelID)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        fetchedAt = try values.decodeIfPresent(Date.self, forKey: .fetchedAt)
        expiresAt = try values.decodeIfPresent(Date.self, forKey: .expiresAt)
        staleReason = try values.decodeIfPresent(String.self, forKey: .staleReason)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encodeIfPresent(subtitle, forKey: .subtitle)
        try values.encode(kind, forKey: .kind)
        try values.encode(items, forKey: .items)
        try values.encode(status, forKey: .status)
        try values.encode(source, forKey: .source)
        try values.encodeIfPresent(cachedOrigin, forKey: .cachedOrigin)
        try values.encodeIfPresent(accountChannelID, forKey: .accountChannelID)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encodeIfPresent(fetchedAt, forKey: .fetchedAt)
        try values.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try values.encodeIfPresent(staleReason, forKey: .staleReason)
    }
}

/// 发现条目:统一已入库曲目快照与 YouTube 发现卡片。
/// 全部为值类型,`HomeSection` 因此可整体缓存。`TrackSnapshot` 非 Hashable,故本枚举
/// 仅提供 `Identifiable`(ForEach 用)而非 `Hashable`。
enum DiscoveryItem: Codable, Sendable, Identifiable {
    case youTube(YouTubeDiscoveryCard)
    case track(TrackSnapshot)

    var id: String {
        switch self {
        case .youTube(let c):  return "yt:\(c.id)"
        case .track(let t):    return "tr:\(t.id.uuidString)"
        }
    }

    var homeMediaIdentity: String? {
        switch self {
        case .youTube(let card):
            if let videoID = card.playableVideoID { return "video:\(videoID)" }
            if let browse = card.browseEndpoint {
                return "\(browse.kind.rawValue):\(browse.identifier)"
            }
            return card.id.isEmpty ? nil : "legacy:\(card.id)"
        case .track(let snapshot):
            return snapshot.youTubeId.isEmpty ? nil : "video:\(snapshot.youTubeId)"
        }
    }
}
