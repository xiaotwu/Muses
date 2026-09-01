import Foundation
import Observation

/// Read-only YouTube account snapshot (Sendable): identity + owned playlists + subscribed channels + liked videos.
/// Fetched from the Data API and cached in `YouTubeAccountService` for UI display and recommendation signals.
struct YouTubeAccountSnapshot: Sendable, Equatable {
    let channel: YouTubeChannel?
    let playlists: [YouTubePlaylist]
    let subscriptions: [YouTubeSubscription]
    let likedVideos: [YouTubeVideo]
}

/// Personalization signals (derived from the account snapshot) for Home/New discovery seed blending.
/// All plain `[String]` values, safe to pass across actors.
struct PersonalizationSignals: Sendable, Equatable {
    /// Channel names of liked videos (deduplicated) — "the artists you like on YouTube".
    let likedArtistNames: [String]
    /// Subscribed channel names (deduplicated) — "the creators you follow".
    let subscribedChannelNames: [String]
    /// Owned playlist titles (deduplicated) for situational reference.
    let playlistTitles: [String]
}

enum YouTubeAccountCapability: String, Sendable, CaseIterable {
    case read
    case managePlaylists
}

/// Provider protocol for personalization signals (implemented by the account service or other local sources).
protocol PersonalizationSignalProviding: Sendable {
    /// Returns the current signals; nil when signed out or disconnected. Must not throw (callers degrade on nil).
    func signals() async -> PersonalizationSignals?
}

/// YouTube account service: OAuth connection management + read-only Data API fetches + personalization signals.
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

    /// Disconnect: clears tokens and the snapshot, keeping the OAuth client configuration.
    func disconnect() {
        session.disconnect()
        isConnected = false
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

    /// Derives the current personalization signals from the cached `account` snapshot (nil without one).
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
