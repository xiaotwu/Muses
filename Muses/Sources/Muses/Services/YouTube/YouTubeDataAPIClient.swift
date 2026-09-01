import Foundation

enum PaginationIncompleteKind: String, Codable, Sendable, Equatable {
    case continuation
    case safetyLimit
    case cancelled
    case timedOut
    case quotaExceeded
    case rateLimited
    case parseFailure
    case requestFailure
}

struct PaginationIncompleteReason: Codable, Sendable, Equatable {
    let kind: PaginationIncompleteKind
    let detail: String?

    init(_ kind: PaginationIncompleteKind, detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }
}

enum PaginationCompleteness: Codable, Sendable, Equatable {
    case complete
    case incomplete(PaginationIncompleteReason)

    var isComplete: Bool {
        if case .complete = self { return true }
        return false
    }
}

struct PaginatedResult<Item: Sendable>: Sendable {
    let items: [Item]
    let completeness: PaginationCompleteness
    let pageCount: Int
    let nextPageToken: String?

    var isComplete: Bool { completeness.isComplete }
}

extension PaginatedResult: Equatable where Item: Equatable {}

struct PaginationPage<Item: Sendable>: Sendable {
    let items: [Item]
    let nextPageToken: String?
}

/// YouTube Data API v3 account and owned-playlist client.
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
    /// Explicit safety ceiling. Normal reads continue until nextPageToken is nil.
    /// At 50 rows/page the default permits 10,000 rows without silent truncation.
    let maxPages: Int

    init(accessTokenProvider: @escaping @Sendable () async throws -> String,
         http: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw DataAPIError.network("非 HTTP 响应") }
            return (data, http)
         },
         maxPages: Int = 200) {
        self.accessTokenProvider = accessTokenProvider
        self.http = http
        self.maxPages = max(1, maxPages)
    }

    enum DataAPIError: LocalizedError, Equatable, Sendable {
        case unauthorized
        case forbidden(String)
        case quotaExceeded
        case rateLimited
        case timedOut
        case notFound
        case paginationLimitReached(Int)
        case unavailable(String)
        case http(Int, String)
        case parse(String)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .unauthorized:
                tr("Unauthorized (token invalid or expired)", "未授权(令牌无效或过期)")
            case .forbidden(let reason):
                tr("YouTube denied this operation: \(reason)", "YouTube 拒绝了此操作：\(reason)")
            case .quotaExceeded:
                tr("YouTube API quota is exhausted. Try again after the quota resets.", "YouTube API 配额已用尽，请在配额重置后重试。")
            case .rateLimited:
                tr("YouTube is receiving too many requests. Try again shortly.", "YouTube 请求过于频繁，请稍后重试。")
            case .timedOut:
                tr("The YouTube request timed out", "YouTube 请求超时")
            case .notFound:
                tr("The YouTube playlist item no longer exists", "该 YouTube 歌单条目已不存在")
            case .paginationLimitReached(let pages):
                tr("YouTube pagination stopped at the \(pages)-page safety limit",
                   "YouTube 分页读取达到 \(pages) 页安全上限")
            case .unavailable(let reason):
                tr("The YouTube item is unavailable: \(reason)", "该 YouTube 条目不可用：\(reason)")
            case .http(let c, let m):
                "YouTube Data API HTTP \(c):\(m)"
            case .parse(let m):
                tr("YouTube Data API parse failed: \(m)", "YouTube Data API 解析失败:\(m)")
            case .network(let m):
                tr("Network error: \(m)", "网络错误:\(m)")
            }
        }

        static func == (lhs: DataAPIError, rhs: DataAPIError) -> Bool {
            String(describing: lhs) == String(describing: rhs)
        }

        var isRetryable: Bool {
            switch self {
            case .rateLimited, .timedOut, .network: true
            case .http(let status, _): status == 408 || status == 429 || status >= 500
            default: false
            }
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

    /// 某歌单的条目(playlistItemId/videoId/title/channel/thumbnail),分页拉取。
    func playlistItems(playlistId: String) async throws -> [YouTubePlaylistItem] {
        let url = "\(Self.base)/playlistItems?part=snippet,contentDetails&playlistId=\(playlistId)&maxResults=50"
        return try await paginateList(url: url, type: PlaylistItemsPage.self, items: { $0.items })
    }

    /// One playlist page. Sync owns the loop so every completed page can be
    /// persisted before requesting the next page.
    func playlistItemsPage(playlistId: String,
                           pageToken: String?) async throws -> PaginationPage<YouTubePlaylistItem> {
        let baseURL = "\(Self.base)/playlistItems?part=snippet,contentDetails&playlistId=\(playlistId)&maxResults=50"
        let fullURL = pageToken.map { "\(baseURL)&pageToken=\($0)" } ?? baseURL
        let data = try await get(fullURL)
        do {
            let page = try JSONDecoder().decode(PlaylistItemsPage.self, from: data)
            return .init(items: page.items, nextPageToken: page.nextPageToken)
        } catch {
            throw DataAPIError.parse(String(describing: error))
        }
    }

    /// Value-returning pagination used by diagnostics and boundary tests. Sync
    /// uses the same page endpoint directly so it can persist after every page.
    func playlistItemsPaginated(
        playlistId: String,
        initialItems: [YouTubePlaylistItem] = [],
        initialPageCount: Int = 0,
        nextPageToken: String? = nil
    ) async -> PaginatedResult<YouTubePlaylistItem> {
        var all = initialItems
        var pageCount = initialPageCount
        var pageToken = nextPageToken
        while pageCount < maxPages {
            if Task.isCancelled {
                return .init(items: all,
                             completeness: .incomplete(.init(.cancelled)),
                             pageCount: pageCount, nextPageToken: pageToken)
            }
            do {
                let page = try await playlistItemsPage(
                    playlistId: playlistId, pageToken: pageToken)
                all.append(contentsOf: page.items)
                pageCount += 1
                pageToken = page.nextPageToken
                if pageToken == nil {
                    return .init(items: all, completeness: .complete,
                                 pageCount: pageCount, nextPageToken: nil)
                }
            } catch {
                return .init(items: all,
                             completeness: .incomplete(Self.paginationReason(for: error)),
                             pageCount: pageCount, nextPageToken: pageToken)
            }
        }
        return .init(
            items: all,
            completeness: .incomplete(
                .init(.safetyLimit, detail: "\(maxPages) pages")),
            pageCount: pageCount,
            nextPageToken: pageToken)
    }

    /// Insert a video into an owned playlist. Returns the new playlistItem id.
    func insertPlaylistItem(playlistId: String, videoId: String, position: Int? = nil) async throws -> String {
        let body = PlaylistItemWriteBody(
            id: nil,
            snippet: .init(playlistId: playlistId, position: position, videoId: videoId))
        let data = try await send(method: "POST",
                                  urlString: "\(Self.base)/playlistItems?part=snippet",
                                  body: body)
        return (try? JSONDecoder().decode(PlaylistItemWriteResponse.self, from: data))?.id ?? ""
    }

    /// Delete a playlist item by its playlistItem resource id.
    func deletePlaylistItem(id: String) async throws {
        _ = try await send(method: "DELETE",
                           urlString: "\(Self.base)/playlistItems?id=\(id)",
                           body: Optional<PlaylistItemWriteBody>.none,
                           allowEmpty: true)
    }

    /// Move an existing playlist item to `position` (0-based).
    func updatePlaylistItemPosition(id: String, playlistId: String, videoId: String, position: Int) async throws {
        let body = PlaylistItemWriteBody(
            id: id,
            snippet: .init(playlistId: playlistId, position: position, videoId: videoId))
        _ = try await send(method: "PUT",
                           urlString: "\(Self.base)/playlistItems?part=snippet",
                           body: body)
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
        try await send(method: "GET", urlString: urlString,
                       body: Optional<PlaylistItemWriteBody>.none)
    }

    private func send<Body: Encodable>(method: String, urlString: String, body: Body?,
                                       allowEmpty: Bool = false) async throws -> Data {
        let token = try await accessTokenProvider()
        guard let url = URL(string: urlString) else { throw DataAPIError.network("非法 URL") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        do {
            let (data, resp) = try await http(req)
            if resp.statusCode == 401 { throw DataAPIError.unauthorized }
            if resp.statusCode == 403 {
                let reason = Self.googleErrorReason(from: data)
                switch reason {
                case "quotaExceeded", "dailyLimitExceeded", "dailyLimitExceededUnreg":
                    throw DataAPIError.quotaExceeded
                case "rateLimitExceeded", "userRateLimitExceeded":
                    throw DataAPIError.rateLimited
                default:
                    throw DataAPIError.forbidden(reason ?? Self.truncate(data))
                }
            }
            if resp.statusCode == 404 { throw DataAPIError.notFound }
            if resp.statusCode == 429 { throw DataAPIError.rateLimited }
            if allowEmpty, (200..<300).contains(resp.statusCode) { return data }
            guard resp.statusCode == 200 || resp.statusCode == 201 else {
                throw DataAPIError.http(resp.statusCode, Self.truncate(data))
            }
            return data
        } catch let e as DataAPIError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw DataAPIError.timedOut
        } catch {
            throw DataAPIError.network(error.localizedDescription)
        }
    }

    /// Non-sync browsing endpoints still use an array, but reaching the safety
    /// ceiling is now an explicit failure instead of returning a truncated list.
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
        if pageToken != nil { throw DataAPIError.paginationLimitReached(maxPages) }
        return all
    }

    nonisolated static func truncate(_ data: Data, maxLength: Int = 200) -> String {
        (String(data: data, encoding: .utf8) ?? "").prefix(maxLength).description
    }

    nonisolated static func googleErrorReason(from data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(GoogleErrorEnvelope.self, from: data) else {
            return nil
        }
        return envelope.error.errors?.first?.reason ?? envelope.error.status
    }

    nonisolated static func paginationReason(for error: Error)
        -> PaginationIncompleteReason {
        if error is CancellationError { return .init(.cancelled) }
        guard let apiError = error as? DataAPIError else {
            return .init(.requestFailure, detail: error.localizedDescription)
        }
        switch apiError {
        case .quotaExceeded:
            return .init(.quotaExceeded)
        case .rateLimited:
            return .init(.rateLimited)
        case .timedOut:
            return .init(.timedOut)
        case .parse(let message):
            return .init(.parseFailure, detail: message)
        case .paginationLimitReached(let pages):
            return .init(.safetyLimit, detail: "\(pages) pages")
        default:
            return .init(.requestFailure, detail: apiError.localizedDescription)
        }
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
    /// YouTube playlistItem resource id (needed for delete/reorder). Empty if unknown.
    let playlistItemId: String
    let videoId: String
    let title: String
    let channelTitle: String
    let thumbnailURL: String?
    let availability: YouTubePlaylistItemAvailability
    enum CodingKeys: String, CodingKey { case id, snippet, contentDetails }
    init(playlistItemId: String = "", videoId: String, title: String, channelTitle: String,
         thumbnailURL: String?, availability: YouTubePlaylistItemAvailability = .available) {
        self.playlistItemId = playlistItemId
        self.videoId = videoId; self.title = title
        self.channelTitle = channelTitle; self.thumbnailURL = thumbnailURL
        self.availability = availability
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.playlistItemId = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        let s = try c.decode(Snippet.self, forKey: .snippet)
        self.title = s.title; self.channelTitle = s.channelTitle
        self.thumbnailURL = s.thumbnails?.high?.url ?? s.thumbnails?.default?.url
        let d = try c.decodeIfPresent(ContentDetails.self, forKey: .contentDetails)
        self.videoId = d?.videoId ?? ""
        if self.title.localizedCaseInsensitiveContains("private video") {
            self.availability = .private
        } else if self.title.localizedCaseInsensitiveContains("deleted video") {
            self.availability = .deleted
        } else if self.videoId.isEmpty {
            self.availability = .unknown
        } else {
            self.availability = .available
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !playlistItemId.isEmpty { try c.encode(playlistItemId, forKey: .id) }
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

private struct PlaylistItemWriteBody: Encodable, Sendable {
    let id: String?
    let snippet: Snippet

    enum CodingKeys: String, CodingKey { case id, snippet }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(snippet, forKey: .snippet)
    }

    struct Snippet: Encodable, Sendable {
        let playlistId: String
        let position: Int?
        let resourceId: ResourceId
        init(playlistId: String, position: Int?, videoId: String) {
            self.playlistId = playlistId
            self.position = position
            self.resourceId = ResourceId(videoId: videoId)
        }
        enum CodingKeys: String, CodingKey { case playlistId, position, resourceId }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(playlistId, forKey: .playlistId)
            try c.encodeIfPresent(position, forKey: .position)
            try c.encode(resourceId, forKey: .resourceId)
        }
    }
    struct ResourceId: Encodable, Sendable {
        let kind = "youtube#video"
        let videoId: String
    }
}

private struct PlaylistItemWriteResponse: Decodable, Sendable {
    let id: String?
}

private struct GoogleErrorEnvelope: Decodable, Sendable {
    let error: Payload
    struct Payload: Decodable, Sendable {
        let errors: [Detail]?
        let status: String?
    }
    struct Detail: Decodable, Sendable {
        let reason: String?
    }
}
