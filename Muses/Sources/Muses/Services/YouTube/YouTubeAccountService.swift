import Foundation
import Observation

/// YouTube 账号只读快照(Sendable):身份 + 拥有的歌单 + 订阅频道 + 点赞视频。
/// 由 Data API 拉取,缓存于 `YouTubeAccountService`,供 UI 展示与推荐信号派生。
struct YouTubeAccountSnapshot: Sendable, Equatable {
    let channel: YouTubeChannel?
    let playlists: [YouTubePlaylist]
    let subscriptions: [YouTubeSubscription]
    let likedVideos: [YouTubeVideo]
}

/// 个性化信号(派生自账号快照),供 Home/New 发现融合种子。
/// 全部为标量 `[String]`,可安全跨 actor。
struct PersonalizationSignals: Sendable, Equatable {
    /// 点赞视频的频道名(去重),作为"你在 YouTube 喜欢的艺术家"。
    let likedArtistNames: [String]
    /// 订阅的频道名(去重),作为"你关注的创作者"。
    let subscribedChannelNames: [String]
    /// 拥有歌单的标题(去重),供情境化参考。
    let playlistTitles: [String]
}

enum YouTubeAccountCapability: String, Sendable, CaseIterable {
    case read
    case managePlaylists
}

/// 个性化信号提供者协议(可由账号服务或其他本地源实现)。
protocol PersonalizationSignalProviding: Sendable {
    /// 返回当前信号;无账号或未连接返回 nil。不得抛出(调用方按 nil 降级)。
    func signals() async -> PersonalizationSignals?
}

/// YouTube 账号服务:OAuth 连接管理 + Data API 只读拉取 + 个性化信号派生。
///
/// `@MainActor @Observable`,便于 UI 绑定 `isConnected` / `account` / `isConnecting`。
/// 离线/令牌过期/配额耗尽/未配置时 `isConnected == false`,所有方法降级为 no-op/nil,
/// 绝不阻断播放(spec §4)。UI 不再把它与 cookie 提取混称"登录";"已连接"专指 OAuth。
@MainActor
@Observable
final class YouTubeAccountService {
    private let session: GoogleOAuthSession
    private let clientFactory: @Sendable (GoogleOAuthSession) -> YouTubeDataAPIClient

    /// 当前连接状态(由 refresh 驱动,UI 绑定)。
    private(set) var isConnected: Bool = false
    /// 当前账号快照(由 refresh 填充)。
    private(set) var account: YouTubeAccountSnapshot?
    /// 正在连接/刷新。
    private(set) var isConnecting: Bool = false
    /// 最近错误信息(UI 展示;nil=无)。
    private(set) var lastError: String?
    private(set) var channelState: LoadState<YouTubeChannel> = .idle
    private(set) var playlistsState: LoadState<[YouTubePlaylist]> = .idle
    private(set) var subscriptionsState: LoadState<[YouTubeSubscription]> = .idle
    private(set) var likedVideosState: LoadState<[YouTubeVideo]> = .idle

    init(session: GoogleOAuthSession = GoogleOAuthSession(keychain: KeychainStore()),
         clientFactory: @escaping @Sendable (GoogleOAuthSession) -> YouTubeDataAPIClient = { session in
            YouTubeDataAPIClient(accessTokenProvider: { [weak session] in
                guard let session else { throw OAuthError.noRefreshToken }
                return try await session.validAccessToken()
            })
         }) {
        self.session = session
        self.clientFactory = clientFactory
        // Construction restores token-backed status synchronously. MusesApp
        // schedules snapshot refresh after dependency composition completes.
        self.isConnected = session.isConnected
    }

    /// Rehydrates the non-persisted account snapshot after an app restart.
    /// The token remains the source of truth; network/API failures retain the
    /// same best-effort behavior as a user-initiated refresh.
    func refreshPersistedConnectionIfNeeded() async {
        guard isConnected, account == nil else { return }
        await refresh()
    }

    // MARK: - Config

    var isOAuthConfigured: Bool { session.loadConfig() != nil }

    var activeChannelID: String? { account?.channel?.id }

    var grantedScopes: [String] {
        session.loadTokens()?.scope?
            .split(separator: " ")
            .map(String.init) ?? []
    }

    var capabilities: Set<YouTubeAccountCapability> {
        let scopes = Set(grantedScopes)
        var result = Set<YouTubeAccountCapability>()
        if scopes.contains(GoogleOAuthConfig.readOnlyScope)
            || scopes.contains(GoogleOAuthConfig.manageScope) {
            result.insert(.read)
        }
        if scopes.contains(GoogleOAuthConfig.manageScope) {
            result.insert(.managePlaylists)
        }
        return result
    }

    var canReadAccount: Bool { capabilities.contains(.read) }
    var canManagePlaylists: Bool { capabilities.contains(.managePlaylists) }

    func loadConfig() -> GoogleOAuthConfig? { session.loadConfig() }

    func saveConfig(_ config: GoogleOAuthConfig) throws {
        try session.saveConfig(config)
        lastError = nil
    }

    func clearConfig() {
        session.clearConfig()
        session.disconnect()
        isConnected = false
        account = nil
    }

    // MARK: - Connect / disconnect

    /// 发起 OAuth 连接(浏览器授权),成功后立即刷新账号快照。
    func connect() async {
        guard session.loadConfig() != nil else {
            lastError = OAuthError.notConfigured.errorDescription
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await session.connect()
            isConnected = session.isConnected
            guard isConnected else {
                lastError = OAuthError.noRefreshToken.errorDescription
                return
            }
            clearAccountSnapshot()
            lastError = nil
            await refresh()
        } catch let e as OAuthError {
            lastError = e.errorDescription
            isConnected = session.isConnected
        } catch {
            lastError = error.localizedDescription
            isConnected = session.isConnected
        }
    }

    /// Incremental authorization: existing read access stays usable when the
    /// user cancels or declines the additional playlist-management scope.
    func requestPlaylistManagementAccess() async {
        guard session.loadConfig() != nil else {
            lastError = OAuthError.notConfigured.errorDescription
            return
        }
        guard isConnected, canReadAccount else {
            await connect()
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await session.connect(
                requestedScopes: [GoogleOAuthConfig.manageScope],
                includeGrantedScopes: true)
            isConnected = session.isConnected
            guard canManagePlaylists else {
                lastError = tr(
                    "YouTube playlist management permission was not granted",
                    "未授予 YouTube 歌单管理权限")
                return
            }
            lastError = nil
            await refresh()
        } catch let error as OAuthError {
            // The old token set was never cleared, so read access survives.
            lastError = error.errorDescription
            isConnected = session.isConnected
        } catch {
            lastError = error.localizedDescription
            isConnected = session.isConnected
        }
    }

    /// 断开连接:清除令牌与快照,保留 OAuth 客户端配置。
    func disconnect() {
        session.disconnect()
        isConnected = false
        clearAccountSnapshot()
        lastError = nil
    }

    /// 刷新账号快照(身份 + 歌单 + 订阅 + 点赞)。分项失败容忍,整体降级不抛出;
    /// 若任一项返回 `unauthorized` 则视为令牌失效,断开连接。
    func refresh() async {
        guard session.isConnected, canReadAccount else {
            if session.isConnected {
                lastError = tr(
                    "Reconnect YouTube to grant read access",
                    "请重新连接 YouTube 以授予读取权限")
            }
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        let client = clientFactory(session)

        let previousChannel = channelState.value ?? account?.channel
        let previousPlaylists = playlistsState.value ?? account?.playlists
        let previousSubscriptions = subscriptionsState.value ?? account?.subscriptions
        let previousLiked = likedVideosState.value ?? account?.likedVideos
        channelState = .loading(previous: previousChannel)
        playlistsState = .loading(previous: previousPlaylists)
        subscriptionsState = .loading(previous: previousSubscriptions)
        likedVideosState = .loading(previous: previousLiked)

        var channel = previousChannel
        var playlists = previousPlaylists ?? []
        var subs = previousSubscriptions ?? []
        var liked = previousLiked ?? []
        var anySuccess = false
        var unauthorized = false
        var firstError: String?

        func handle(_ error: Error) {
            if let e = error as? YouTubeDataAPIClient.DataAPIError {
                if case .unauthorized = e { unauthorized = true }
                firstError = firstError ?? e.errorDescription
            } else {
                firstError = firstError ?? error.localizedDescription
            }
        }

        do {
            channel = try await client.channel()
            channelState = channel.map(LoadState.content) ?? .empty
            anySuccess = true
        } catch {
            handle(error)
            channelState = .failure(message: error.localizedDescription,
                                    staleValue: previousChannel)
        }
        do {
            playlists = try await client.myPlaylists()
            playlistsState = playlists.isEmpty ? .empty : .content(playlists)
            anySuccess = true
        } catch {
            handle(error)
            playlistsState = .failure(message: error.localizedDescription,
                                      staleValue: previousPlaylists)
        }
        do {
            subs = try await client.subscriptions()
            subscriptionsState = subs.isEmpty ? .empty : .content(subs)
            anySuccess = true
        } catch {
            handle(error)
            subscriptionsState = .failure(message: error.localizedDescription,
                                          staleValue: previousSubscriptions)
        }
        do {
            liked = try await client.likedVideos()
            likedVideosState = liked.isEmpty ? .empty : .content(liked)
            anySuccess = true
        } catch {
            handle(error)
            likedVideosState = .failure(message: error.localizedDescription,
                                        staleValue: previousLiked)
        }

        if unauthorized {
            session.disconnect()
            isConnected = false
            clearAccountSnapshot()
            lastError = firstError
            return
        }
        self.account = YouTubeAccountSnapshot(
            channel: channel, playlists: playlists, subscriptions: subs, likedVideos: liked)
        // 任一成功即清除上次错误(部分成功视为可用);全失败则保留错误。
        lastError = anySuccess ? nil : firstError
    }

    private func clearAccountSnapshot() {
        account = nil
        channelState = .idle
        playlistsState = .idle
        subscriptionsState = .idle
        likedVideosState = .idle
    }

    // MARK: - Signals

    /// True when the connected account owns this YouTube playlist id.
    func ownsPlaylist(_ playlistId: String) -> Bool {
        guard isConnected, !playlistId.isEmpty else { return false }
        return account?.playlists.contains(where: { $0.id == playlistId }) == true
    }

    func playlistWriter() -> YouTubePlaylistWriteService? {
        guard isConnected, canManagePlaylists else { return nil }
        return YouTubePlaylistWriteService(client: clientFactory(session))
    }

    func dataAPIClient() -> YouTubeDataAPIClient? {
        guard isConnected, canReadAccount else { return nil }
        return clientFactory(session)
    }

    /// 派生当前个性化信号(从已缓存的 `account` 快照;无快照返回 nil)。
    func signals() -> PersonalizationSignals? {
        guard let snap = account else { return nil }
        let liked = snap.likedVideos.map(\.channelTitle).dedupePreservingOrder()
        let subs = snap.subscriptions.map(\.title).dedupePreservingOrder()
        let playlists = snap.playlists.map(\.title).dedupePreservingOrder()
        return PersonalizationSignals(
            likedArtistNames: liked,
            subscribedChannelNames: subs,
            playlistTitles: playlists)
    }
}

private extension Array where Element == String {
    func dedupePreservingOrder(limit: Int = 20) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for v in self {
            let key = v.lowercased()
            if !key.isEmpty, seen.insert(key).inserted {
                out.append(v)
                if out.count >= limit { break }
            }
        }
        return out
    }
}
