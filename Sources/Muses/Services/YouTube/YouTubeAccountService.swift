import Foundation
import Observation

/// Read-only YouTube account snapshot (Sendable): identity + owned playlists + subscribed channels + liked videos.
/// Fetched from the Data API and cached for account-facing UI and playlist ownership checks.
struct YouTubeAccountSnapshot: Sendable, Equatable {
    let channel: YouTubeChannel?
    let playlists: [YouTubePlaylist]
    let subscriptions: [YouTubeSubscription]
    let likedVideos: [YouTubeVideo]
}

enum YouTubeAccountCapability: String, Sendable, CaseIterable {
    case read
    case managePlaylists
}

enum YouTubeAccountConnectionState: Equatable, Sendable {
    case signedOut
    case connected
    case expired
}

/// YouTube account service: OAuth connection management and read-only Data API fetches.
///
/// `@MainActor @Observable` so the UI can bind `isConnected` / `account` / `isConnecting`.
/// When offline / token expired / quota exhausted / unconfigured, `isConnected == false` and every method degrades to a no-op or nil,
/// never blocking playback. The UI no longer conflates this with cookie extraction as "sign-in"; "connected" refers to OAuth only.
@MainActor
@Observable
final class YouTubeAccountService {
    private let session: GoogleOAuthSession
    private let clientFactory: @Sendable (GoogleOAuthSession) -> YouTubeDataAPIClient

    /// Current connection state (driven by refresh, bound to the UI).
    private(set) var isConnected: Bool = false
    /// Keeps an expired OAuth session distinguishable from an intentional sign-out.
    /// The distinction gives the UI a direct recovery action without conflating
    /// OAuth with browser cookies or Web Home.
    private(set) var connectionState: YouTubeAccountConnectionState = .signedOut
    /// Current account snapshot (filled by refresh).
    private(set) var account: YouTubeAccountSnapshot?
    /// Connecting or refreshing.
    private(set) var isConnecting: Bool = false
    /// Latest error message (shown in the UI; nil = none).
    private(set) var lastError: String?
    private(set) var channelState: LoadState<YouTubeChannel> = .idle
    private(set) var playlistsState: LoadState<[YouTubePlaylist]> = .idle
    private(set) var subscriptionsState: LoadState<[YouTubeSubscription]> = .idle
    private(set) var likedVideosState: LoadState<[YouTubeVideo]> = .idle
    @ObservationIgnored private var refreshGeneration: UInt64 = 0

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
        self.connectionState = session.isConnected ? .connected : .signedOut
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
        refreshGeneration &+= 1
        session.clearConfig()
        session.disconnect()
        isConnected = false
        isConnecting = false
        connectionState = .signedOut
        account = nil
    }

    // MARK: - Connect / disconnect

    /// Starts the OAuth connection (browser authorization) and refreshes the account snapshot on success.
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
            connectionState = isConnected ? .connected : .signedOut
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
            connectionState = isConnected ? .connected : .signedOut
        } catch {
            lastError = error.localizedDescription
            isConnected = session.isConnected
        }
    }

    /// Native OAuth requests the complete desired scope set on each consent.
    /// Existing tokens stay usable when the user cancels the new request.
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
            let previousTokens = session.loadTokens()
            try await session.connect(
                requestedScopes: scopesForAuthorization(adding: GoogleOAuthConfig.manageScope))
            isConnected = session.isConnected
            guard canManagePlaylists else {
                if let previousTokens { try session.storeTokens(previousTokens) }
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

    func scopesForAuthorization(adding scope: String) -> [String] {
        var scopes = [GoogleOAuthConfig.readOnlyScope]
        let supported = Set([GoogleOAuthConfig.readOnlyScope,
                             GoogleOAuthConfig.manageScope])
        for existing in grantedScopes where supported.contains(existing) && !scopes.contains(existing) {
            scopes.append(existing)
        }
        if !scopes.contains(scope) { scopes.append(scope) }
        return scopes
    }

    /// Disconnect: clears tokens and the snapshot, keeping the OAuth client configuration.
    func disconnect() {
        refreshGeneration &+= 1
        session.disconnect()
        isConnected = false
        isConnecting = false
        connectionState = .signedOut
        clearAccountSnapshot()
        lastError = nil
    }

    /// Refreshes the account snapshot (identity + playlists + subscriptions + likes). Individual failures are tolerated and the whole refresh degrades without throwing;
    /// any `unauthorized` result is treated as token invalidation and disconnects.
    func refresh() async {
        guard session.isConnected, canReadAccount else {
            if session.isConnected {
                lastError = tr(
                    "Reconnect YouTube to grant read access",
                    "请重新连接 YouTube 以授予读取权限")
            }
            return
        }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isConnecting = true
        defer {
            if refreshGeneration == generation { isConnecting = false }
        }
        let client = clientFactory(session)

        let previousChannel = channelState.value ?? account?.channel
        let previousPlaylists = playlistsState.value ?? account?.playlists
        let previousSubscriptions = subscriptionsState.value ?? account?.subscriptions
        let previousLiked = likedVideosState.value ?? account?.likedVideos
        let priorChannelState = channelState
        let priorPlaylistsState = playlistsState
        let priorSubscriptionsState = subscriptionsState
        let priorLikedVideosState = likedVideosState
        func restoreCancelledRefresh() {
            guard refreshGeneration == generation else { return }
            channelState = priorChannelState
            playlistsState = priorPlaylistsState
            subscriptionsState = priorSubscriptionsState
            likedVideosState = priorLikedVideosState
        }
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
            } else if let e = error as? OAuthError {
                if e == .authorizationExpired || e == .noRefreshToken {
                    unauthorized = true
                }
                firstError = firstError ?? e.errorDescription
            } else {
                firstError = firstError ?? error.localizedDescription
            }
        }

        do {
            channel = try await client.channel()
            guard refreshGeneration == generation, !Task.isCancelled else {
                restoreCancelledRefresh()
                return
            }
            channelState = channel.map(LoadState.content) ?? .empty
            anySuccess = true
        } catch {
            if refreshGeneration != generation || Task.isCancelled || error is CancellationError {
                restoreCancelledRefresh()
                return
            }
            handle(error)
            channelState = .failure(message: error.localizedDescription,
                                    staleValue: previousChannel)
        }
        do {
            playlists = try await client.myPlaylists()
            guard refreshGeneration == generation, !Task.isCancelled else {
                restoreCancelledRefresh()
                return
            }
            playlistsState = playlists.isEmpty ? .empty : .content(playlists)
            anySuccess = true
        } catch {
            if refreshGeneration != generation || Task.isCancelled || error is CancellationError {
                restoreCancelledRefresh()
                return
            }
            handle(error)
            playlistsState = .failure(message: error.localizedDescription,
                                      staleValue: previousPlaylists)
        }
        do {
            subs = try await client.subscriptions()
            guard refreshGeneration == generation, !Task.isCancelled else {
                restoreCancelledRefresh()
                return
            }
            subscriptionsState = subs.isEmpty ? .empty : .content(subs)
            anySuccess = true
        } catch {
            if refreshGeneration != generation || Task.isCancelled || error is CancellationError {
                restoreCancelledRefresh()
                return
            }
            handle(error)
            subscriptionsState = .failure(message: error.localizedDescription,
                                          staleValue: previousSubscriptions)
        }
        do {
            liked = try await client.likedVideos()
            guard refreshGeneration == generation, !Task.isCancelled else {
                restoreCancelledRefresh()
                return
            }
            likedVideosState = liked.isEmpty ? .empty : .content(liked)
            anySuccess = true
        } catch {
            if refreshGeneration != generation || Task.isCancelled || error is CancellationError {
                restoreCancelledRefresh()
                return
            }
            handle(error)
            likedVideosState = .failure(message: error.localizedDescription,
                                        staleValue: previousLiked)
        }

        if refreshGeneration != generation || Task.isCancelled {
            restoreCancelledRefresh()
            return
        }
        if unauthorized {
            session.disconnect()
            isConnected = false
            connectionState = .expired
            clearAccountSnapshot()
            lastError = firstError
            return
        }
        self.account = YouTubeAccountSnapshot(
            channel: channel, playlists: playlists, subscriptions: subs, likedVideos: liked)
        // Clear the previous error when any section succeeds (partial success counts as usable); keep it only when everything fails.
        lastError = anySuccess ? nil : firstError
    }

    private func clearAccountSnapshot() {
        account = nil
        channelState = .idle
        playlistsState = .idle
        subscriptionsState = .idle
        likedVideosState = .idle
    }

    /// True when the connected account owns this YouTube playlist id.
    func ownsPlaylist(_ playlistId: String) -> Bool {
        guard isConnected, !playlistId.isEmpty else { return false }
        return account?.playlists.contains(where: { $0.id == playlistId }) == true
    }

    func playlistWriter() -> YouTubePlaylistWriteService? {
        guard isConnected, canManagePlaylists else { return nil }
        return YouTubePlaylistWriteService(client: clientFactory(session))
    }

    /// Subscription writes share the explicit manage-scope gate with playlist
    /// writes. Refresh only after the server acknowledges the mutation, so a
    /// failed request cannot create a local phantom subscription.
    func subscribe(channelID: String) async throws {
        guard isConnected, canManagePlaylists else { throw YouTubeAccountWriteError.manageScopeRequired }
        guard channelID.hasPrefix("UC"), channelID.count == 24,
              MusicCatalogParser.validID(channelID),
              let ownerID = activeChannelID else { throw YouTubeAccountWriteError.invalidTarget }
        let client = clientFactory(session)
        let before = try await client.subscriptions()
        guard activeChannelID == ownerID else { throw YouTubeAccountWriteError.accountChanged }
        if before.contains(where: { $0.channelId == channelID }) { return }
        _ = try await client.subscribe(channelId: channelID)
        guard activeChannelID == ownerID else { throw YouTubeAccountWriteError.accountChanged }
        let after = try await client.subscriptions()
        guard after.contains(where: { $0.channelId == channelID }) else {
            throw YouTubeAccountWriteError.readbackUnconfirmed
        }
        await refresh()
    }

    func unsubscribe(subscriptionID: String) async throws {
        guard isConnected, canManagePlaylists else { throw YouTubeAccountWriteError.manageScopeRequired }
        guard let ownerID = activeChannelID else { throw YouTubeAccountWriteError.invalidTarget }
        let client = clientFactory(session)
        let before = try await client.subscriptions()
        guard activeChannelID == ownerID else { throw YouTubeAccountWriteError.accountChanged }
        guard before.contains(where: { $0.id == subscriptionID }) else {
            throw YouTubeAccountWriteError.invalidTarget
        }
        try await client.unsubscribe(subscriptionId: subscriptionID)
        guard activeChannelID == ownerID else { throw YouTubeAccountWriteError.accountChanged }
        let after = try await client.subscriptions()
        guard !after.contains(where: { $0.id == subscriptionID }) else {
            throw YouTubeAccountWriteError.readbackUnconfirmed
        }
        await refresh()
    }

    func dataAPIClient() -> YouTubeDataAPIClient? {
        guard isConnected, canReadAccount else { return nil }
        return clientFactory(session)
    }


}

enum YouTubeAccountWriteError: LocalizedError, Equatable, Sendable {
    case manageScopeRequired
    case invalidTarget
    case accountChanged
    case readbackUnconfirmed

    var errorDescription: String? {
        switch self {
        case .manageScopeRequired:
            tr("Reconnect YouTube with account-management permission to change subscriptions.",
               "请使用账号管理权限重新连接 YouTube，才能修改订阅。",
               zhHant: "請使用帳號管理權限重新連接 YouTube，才能修改訂閱。")
        case .invalidTarget:
            tr("The subscription target is no longer available. Refresh and try again.",
               "订阅目标已不可用，请刷新后重试。", zhHant: "訂閱目標已無法使用，請重新整理後再試。")
        case .accountChanged:
            tr("The connected YouTube account changed. Review the target again.",
               "连接的 YouTube 账号已变更，请重新确认目标。",
               zhHant: "連接的 YouTube 帳號已變更，請重新確認目標。")
        case .readbackUnconfirmed:
            tr("YouTube did not confirm the change. Refresh before trying again.",
               "YouTube 尚未确认更改，请先刷新再决定是否重试。",
               zhHant: "YouTube 尚未確認變更，請先重新整理再決定是否重試。")
        }
    }
}
