import Foundation

/// YouTube Data API v3 只读客户端。
///
/// 仅用于账号身份与个性化信号(channels/playlists/playlistItems/subscriptions/videos?myRating=like),
/// 用 OAuth `Bearer` 令牌请求;不调用 YouTube Music 内部 API,不替代 yt-dlp 的播放/导入(spec §4)。
/// 所有结果为 Sendable 值类型,可安全跨线程喂给 `YouTubeAccountSnapshot` 与推荐信号。
struct YouTubeDataAPIClient {
    static let base = "https://www.googleapis.com/youtube/v3"

    /// 注入的 HTTP 传输(默认 URLSession);测试可替换。
    let http: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    /// 返回有效 access token 的闭包(来自 GoogleOAuthSession.validAccessToken)。
    let accessTokenProvider: @Sendable () async throws -> String
    /// 分页上限(每页 50,默认最多 3 页 ≈ 150 条),避免一次性拉爆配额。
    let maxPages: Int

    init(accessTokenProvider: @escaping @Sendable () async throws -> String,
         http: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw DataAPIError.network("非 HTTP 响应") }
            return (data, http)
         },
         maxPages: Int = 3) {
        self.accessTokenProvider = accessTokenProvider
        self.http = http
        self.maxPages = max(1, maxPages)
    }

    enum DataAPIError: LocalizedError, Equatable, Sendable {
        case unauthorized
        case http(Int, String)
        case parse(String)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .unauthorized: "未授权(令牌无效或过期)"
            case .http(let c, let m): "YouTube Data API HTTP \(c):\(m)"
            case .parse(let m): "YouTube Data API 解析失败:\(m)"
            case .network(let m): "网络错误:\(m)"
            }
        }

        static func == (lhs: DataAPIError, rhs: DataAPIError) -> Bool {
            String(describing: lhs) == String(describing: rhs)
        }
    }

    // MARK: - Endpoints

    /// 当前账号频道身份。
    func channel() async throws -> YouTubeChannel {
        let url = "\(Self.base)/channels?part=snippet&mine=true"
        let data = try await get(url)
        let resp = try JSONDecoder().decode(ChannelListResponse.self, from: data)
        guard let ch = resp.items.first else { throw DataAPIError.parse("无频道") }
        return ch
    }

    /// 当前账号拥有的歌单(id/title/thumbnail/itemCount),分页拉取。
    func myPlaylists() async throws -> [YouTubePlaylist] {
        try await paginateList(url: "\(Self.base)/playlists?part=snippet,contentDetails&mine=true&maxResults=50",
                               type: PlaylistListPage.self,
                               items: { $0.items })
    }

    /// 某歌单的条目(videoId/title/channel/thumbnail),分页拉取。
    func playlistItems(playlistId: String) async throws -> [YouTubePlaylistItem] {
        let url = "\(Self.base)/playlistItems?part=snippet,contentDetails&playlistId=\(playlistId)&maxResults=50"
        return try await paginateList(url: url, type: PlaylistItemsPage.self, items: { $0.items })
    }

    /// 当前账号订阅的频道(id/title/thumbnail),分页拉取。
    func subscriptions() async throws -> [YouTubeSubscription] {
        try await paginateList(url: "\(Self.base)/subscriptions?part=snippet&mine=true&maxResults=50",
                               type: SubscriptionsPage.self,
                               items: { $0.items })
    }

    /// 当前账号点赞过的视频(id/title/channel/thumbnail),分页拉取。
    func likedVideos() async throws -> [YouTubeVideo] {
        try await paginateList(url: "\(Self.base)/videos?part=snippet&myRating=like&maxResults=50",
                               type: VideosPage.self,
                               items: { $0.items })
    }

    // MARK: - Helpers

    private func get(_ urlString: String) async throws -> Data {
        let token = try await accessTokenProvider()
        guard let url = URL(string: urlString) else { throw DataAPIError.network("非法 URL") }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await http(req)
            if resp.statusCode == 401 || resp.statusCode == 403 { throw DataAPIError.unauthorized }
            guard resp.statusCode == 200 else {
                throw DataAPIError.http(resp.statusCode, Self.truncate(data))
            }
            return data
        } catch let e as DataAPIError {
            throw e
        } catch {
            throw DataAPIError.network(error.localizedDescription)
        }
    }

    /// 分页:循环拉取直到无 nextPageToken 或达到 maxPages,合并 items。
    private func paginateList<Page: Decodable & PageTokened, Item>(
        url urlString: String,
        type: Page.Type,
        items: (Page) -> [Item]
    ) async throws -> [Item] {
        var all: [Item] = []
        var pageToken: String? = nil
        let decoder = JSONDecoder()
        for _ in 0..<maxPages {
            let full = pageToken.map { "\(urlString)&pageToken=\($0)" } ?? urlString
            let data = try await get(full)
            let page: Page
            do { page = try decoder.decode(Page.self, from: data) } catch {
                throw DataAPIError.parse(String(describing: error))
            }
            all.append(contentsOf: items(page))
            pageToken = page.nextPageToken
            if pageToken == nil { break }
        }
        return all
    }

    nonisolated static func truncate(_ data: Data, maxLength: Int = 200) -> String {
        (String(data: data, encoding: .utf8) ?? "").prefix(maxLength).description
    }
}

/// 分页响应共性:可提供 nextPageToken。
protocol PageTokened {
    var nextPageToken: String? { get }
}

// MARK: - Value types (Sendable)

struct YouTubeChannel: Codable, Sendable, Equatable {
    let id: String
    let title: String
    let thumbnailURL: String?
    enum CodingKeys: String, CodingKey {
        case id, snippet
    }
    init(id: String, title: String, thumbnailURL: String?) {
        self.id = id; self.title = title; self.thumbnailURL = thumbnailURL
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        let s = try c.decode(Snippet.self, forKey: .snippet)
        self.title = s.title
        self.thumbnailURL = s.thumbnails?.high?.url ?? s.thumbnails?.default?.url
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(Snippet(title: title, thumbnails: nil), forKey: .snippet)
    }
    struct Snippet: Codable, Sendable {
        let title: String
        let thumbnails: Thumbnails?
    }
    struct Thumbnails: Codable, Sendable {
        let `default`: Thumb?
        let high: Thumb?
        enum CodingKeys: String, CodingKey { case `default` = "default"; case high }
    }
    struct Thumb: Codable, Sendable { let url: String }
}

struct YouTubePlaylist: Codable, Sendable, Equatable {
    let id: String
    let title: String
    let thumbnailURL: String?
    let itemCount: Int
    enum CodingKeys: String, CodingKey { case id, snippet, contentDetails }
    init(id: String, title: String, thumbnailURL: String?, itemCount: Int) {
        self.id = id; self.title = title; self.thumbnailURL = thumbnailURL; self.itemCount = itemCount
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        let s = try c.decode(Snippet.self, forKey: .snippet)
        self.title = s.title
        self.thumbnailURL = s.thumbnails?.high?.url ?? s.thumbnails?.default?.url
        let d = try c.decodeIfPresent(ContentDetails.self, forKey: .contentDetails)
        self.itemCount = d?.itemCount ?? 0
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(Snippet(title: title, thumbnails: nil), forKey: .snippet)
        try c.encodeIfPresent(ContentDetails(itemCount: itemCount), forKey: .contentDetails)
    }
    struct Snippet: Codable, Sendable { let title: String; let thumbnails: YouTubeChannel.Thumbnails? }
    struct ContentDetails: Codable, Sendable { let itemCount: Int }
}

struct YouTubePlaylistItem: Codable, Sendable, Equatable {
    let videoId: String
    let title: String
    let channelTitle: String
    let thumbnailURL: String?
    enum CodingKeys: String, CodingKey { case snippet, contentDetails }
    init(videoId: String, title: String, channelTitle: String, thumbnailURL: String?) {
        self.videoId = videoId; self.title = title
        self.channelTitle = channelTitle; self.thumbnailURL = thumbnailURL
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let s = try c.decode(Snippet.self, forKey: .snippet)
        self.title = s.title; self.channelTitle = s.channelTitle
        self.thumbnailURL = s.thumbnails?.high?.url ?? s.thumbnails?.default?.url
        let d = try c.decodeIfPresent(ContentDetails.self, forKey: .contentDetails)
        self.videoId = d?.videoId ?? ""
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Snippet(title: title, channelTitle: channelTitle, thumbnails: nil), forKey: .snippet)
        try c.encodeIfPresent(ContentDetails(videoId: videoId), forKey: .contentDetails)
    }
    struct Snippet: Codable, Sendable {
        let title: String; let channelTitle: String; let thumbnails: YouTubeChannel.Thumbnails?
    }
    struct ContentDetails: Codable, Sendable { let videoId: String }
}

struct YouTubeSubscription: Codable, Sendable, Equatable {
    let channelId: String
    let title: String
    let thumbnailURL: String?
    enum CodingKeys: String, CodingKey { case snippet }
    init(channelId: String, title: String, thumbnailURL: String?) {
        self.channelId = channelId; self.title = title; self.thumbnailURL = thumbnailURL
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let s = try c.decode(Snippet.self, forKey: .snippet)
        self.title = s.title; self.thumbnailURL = s.thumbnails?.high?.url ?? s.thumbnails?.default?.url
        self.channelId = s.resourceId?.channelId ?? ""
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Snippet(title: title, thumbnails: nil, resourceId: nil), forKey: .snippet)
    }
    struct Snippet: Codable, Sendable {
        let title: String; let thumbnails: YouTubeChannel.Thumbnails?
        let resourceId: ResourceId?
    }
    struct ResourceId: Codable, Sendable { let channelId: String }
}

struct YouTubeVideo: Codable, Sendable, Equatable {
    let id: String
    let title: String
    let channelTitle: String
    let thumbnailURL: String?
    enum CodingKeys: String, CodingKey { case id, snippet }
    init(id: String, title: String, channelTitle: String, thumbnailURL: String?) {
        self.id = id; self.title = title; self.channelTitle = channelTitle; self.thumbnailURL = thumbnailURL
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        let s = try c.decode(Snippet.self, forKey: .snippet)
        self.title = s.title; self.channelTitle = s.channelTitle
        self.thumbnailURL = s.thumbnails?.high?.url ?? s.thumbnails?.default?.url
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(Snippet(title: title, channelTitle: channelTitle, thumbnails: nil), forKey: .snippet)
    }
    struct Snippet: Codable, Sendable {
        let title: String; let channelTitle: String; let thumbnails: YouTubeChannel.Thumbnails?
    }
}

// MARK: - Page responses

private struct ChannelListResponse: Codable, Sendable {
    let items: [YouTubeChannel]
}
private struct PlaylistListPage: Decodable, PageTokened {
    let items: [YouTubePlaylist]
    let nextPageToken: String?
}
private struct PlaylistItemsPage: Decodable, PageTokened {
    let items: [YouTubePlaylistItem]
    let nextPageToken: String?
}
private struct SubscriptionsPage: Decodable, PageTokened {
    let items: [YouTubeSubscription]
    let nextPageToken: String?
}
private struct VideosPage: Decodable, PageTokened {
    let items: [YouTubeVideo]
    let nextPageToken: String?
}