import Testing
import Foundation
import CryptoKit
@testable import Muses

/// P2 — YouTube OAuth + Keychain + Data API + 个性化信号 合并 单元测试。
///
/// 全部为纯逻辑/可注入 stub 验证,不触达真实 Keychain、ASWebAuthenticationSession、网络。
/// `@MainActor` 因 `GoogleOAuthSession` / `YouTubeAccountService` 为 @MainActor(Swift Testing
/// 支持以隔离类型标注 actor)。
@MainActor
struct PhaseP2OAuthTests {

    // MARK: - Keychain (InMemory)

    @Test("InMemoryKeychain: set/get/delete 往返")
    func keychainRoundtrip() {
        let kc = InMemoryKeychain()
        let payload = Data("secret".utf8)
        #expect(kc.set(payload, for: "a") == true)
        #expect(kc.data(for: "a") == payload)
        #expect(kc.delete("a") == true)
        #expect(kc.data(for: "a") == nil)
    }

    @Test("InMemoryKeychain: 覆盖写入 + 删除不存在返回 true")
    func keychainOverwriteAndMissingDelete() {
        let kc = InMemoryKeychain()
        _ = kc.set(Data([1]), for: "k")
        _ = kc.set(Data([2]), for: "k")
        #expect(kc.data(for: "k") == Data([2]))
        #expect(kc.delete("never") == true)
    }

    // MARK: - OAuth config / tokens

    @Test("GoogleOAuthSession: saveConfig/loadConfig 往返;空值拒绝")
    func configRoundtrip() throws {
        let kc = InMemoryKeychain()
        let session = GoogleOAuthSession(keychain: kc, presenter: StubPresenter(), tokenExchange: stubExchange)
        let cfg = GoogleOAuthConfig(
            clientID: "cid", clientSecret: "csec",
            redirectURI: "muses:/oauth", scopes: GoogleOAuthConfig.defaultScopes)
        try session.saveConfig(cfg)
        let loaded = session.loadConfig()
        #expect(loaded?.clientID == "cid")
        #expect(loaded?.redirectScheme == "muses")
        #expect(throws: OAuthError.notConfigured) {
            try session.saveConfig(GoogleOAuthConfig(clientID: "", clientSecret: "", redirectURI: "", scopes: []))
        }
    }

    @Test("OAuthTokenSet: isAccessExpired 60s 边界")
    func tokenExpiry() {
        let now = Date()
        let fresh = OAuthTokenSet(accessToken: "a", refreshToken: "r",
                                  expiresAt: now.addingTimeInterval(120), scope: nil)
        let stale = OAuthTokenSet(accessToken: "a", refreshToken: "r",
                                  expiresAt: now.addingTimeInterval(30), scope: nil) // 30s < 60s margin
        let past = OAuthTokenSet(accessToken: "a", refreshToken: "r",
                                 expiresAt: now.addingTimeInterval(-10), scope: nil)
        #expect(fresh.isAccessExpired == false)
        #expect(stale.isAccessExpired == true)
        #expect(past.isAccessExpired == true)
    }

    // MARK: - PKCE helpers (pure)

    @Test("PKCE: codeChallenge 可复现(SHA256 base64url);verifier 唯一")
    func pkceDeterministic() {
        let verifier = "test-verifier-12345"
        let ch1 = GoogleOAuthSession.codeChallenge(for: verifier)
        let ch2 = GoogleOAuthSession.codeChallenge(for: verifier)
        #expect(ch1 == ch2)
        // SHA256 摘要 = 32 字节 → base64url 无填充约 43 字符。
        #expect(ch1.contains("=") == false) // base64url 无填充
        #expect(ch1.contains("+") == false) // base64url 用 - _ 而非 + /
        let expectedRaw = Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(ch1 == expectedRaw)
        let a = GoogleOAuthSession.generateCodeVerifier()
        let b = GoogleOAuthSession.generateCodeVerifier()
        #expect(a != b)
        #expect(a.count >= 40)
    }

    // MARK: - connect() flow (stub presenter + stub token exchange)

    @Test("connect(): 成功存令牌(refresh token 非空,isConnected=true)")
    func connectSuccess() async throws {
        let kc = InMemoryKeychain()
        let presenter = StubPresenter()
        let session = GoogleOAuthSession(keychain: kc, presenter: presenter, tokenExchange: stubExchange)
        try session.saveConfig(GoogleOAuthConfig(
            clientID: "cid", clientSecret: "csec",
            redirectURI: "muses:/oauth", scopes: []))
        try await session.connect()
        let tokens = session.loadTokens()
        #expect(tokens?.accessToken == "AT")
        #expect(tokens?.refreshToken == "RT")
        #expect(session.isConnected == true)
    }

    @Test("OAuth defaults to read-only and incremental upgrade requests granted scopes")
    func leastPrivilegeAndIncrementalUpgrade() async throws {
        #expect(GoogleOAuthConfig.defaultScopes == [GoogleOAuthConfig.readOnlyScope])
        let keychain = InMemoryKeychain()
        let presenter = StubPresenter()
        let session = GoogleOAuthSession(
            keychain: keychain, presenter: presenter,
            tokenExchange: { _ in
                let body = #"{"access_token":"AT2","expires_in":3600,"scope":"https://www.googleapis.com/auth/youtube https://www.googleapis.com/auth/youtube.readonly"}"#
                return (Data(body.utf8), Self.http200())
            })
        try session.saveConfig(GoogleOAuthConfig(
            clientID: "cid", clientSecret: "csec",
            redirectURI: "muses:/oauth", scopes: []))
        try session.storeTokens(OAuthTokenSet(
            accessToken: "AT1", refreshToken: "RT",
            expiresAt: .now.addingTimeInterval(3600),
            scope: GoogleOAuthConfig.readOnlyScope))

        try await session.connect(
            requestedScopes: [GoogleOAuthConfig.manageScope],
            includeGrantedScopes: true)

        let items = URLComponents(
            url: try #require(presenter.lastAuthURL),
            resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first(where: { $0.name == "scope" })?.value
                == GoogleOAuthConfig.manageScope)
        #expect(items.first(where: { $0.name == "include_granted_scopes" })?.value
                == "true")
        #expect(session.loadTokens()?.refreshToken == "RT")
    }

    @Test("readonly capability cannot create a writer; granted manage scope can")
    func writerRequiresActuallyGrantedManageScope() throws {
        let keychain = InMemoryKeychain()
        let session = GoogleOAuthSession(keychain: keychain)
        try session.storeTokens(OAuthTokenSet(
            accessToken: "AT", refreshToken: "RT",
            expiresAt: .now.addingTimeInterval(3600),
            scope: GoogleOAuthConfig.readOnlyScope))
        let account = YouTubeAccountService(session: session)
        #expect(account.canReadAccount)
        #expect(!account.canManagePlaylists)
        #expect(account.playlistWriter() == nil)

        try session.storeTokens(OAuthTokenSet(
            accessToken: "AT", refreshToken: "RT",
            expiresAt: .now.addingTimeInterval(3600),
            scope: GoogleOAuthConfig.manageScope))
        #expect(account.canReadAccount)
        #expect(account.canManagePlaylists)
        #expect(account.playlistWriter() != nil)
    }

    @Test("connect(): 用户取消(presenter 返回 nil)抛 userCancelled")
    func connectCancelled() async throws {
        let kc = InMemoryKeychain()
        let presenter = StubPresenter(returnsURL: false)
        let session = GoogleOAuthSession(keychain: kc, presenter: presenter, tokenExchange: stubExchange)
        try session.saveConfig(GoogleOAuthConfig(
            clientID: "cid", clientSecret: "csec",
            redirectURI: "muses:/oauth", scopes: []))
        await #expect(throws: OAuthError.userCancelled) {
            try await session.connect()
        }
        #expect(session.isConnected == false)
    }

    @Test("connect(): 未配置凭证抛 notConfigured")
    func connectNotConfigured() async {
        let kc = InMemoryKeychain()
        let session = GoogleOAuthSession(keychain: kc, presenter: StubPresenter(), tokenExchange: stubExchange)
        await #expect(throws: OAuthError.notConfigured) {
            try await session.connect()
        }
    }

    // MARK: - refresh()

    @Test("refresh(): 刷新令牌;响应缺 refresh_token 时沿用旧值")
    func refreshPreservesRefreshToken() async throws {
        let kc = InMemoryKeychain()
        // 预置已存令牌(含 refresh token)。
        let existing = OAuthTokenSet(
            accessToken: "oldAT", refreshToken: "RT",
            expiresAt: Date().addingTimeInterval(-60), scope: "youtube.readonly")
        let session = GoogleOAuthSession(keychain: kc, presenter: StubPresenter(), tokenExchange: { req in
            // 刷新响应:新 access,无 refresh_token。
            let body = #"{"access_token":"newAT","expires_in":3600}"#
            return (Data(body.utf8), Self.http200())
        })
        try session.storeTokens(existing)
        try session.saveConfig(GoogleOAuthConfig(
            clientID: "cid", clientSecret: "csec",
            redirectURI: "muses:/oauth", scopes: []))
        let access = try await session.refresh()
        #expect(access == "newAT")
        let after = session.loadTokens()
        #expect(after?.accessToken == "newAT")
        #expect(after?.refreshToken == "RT") // 沿用旧 refresh
    }

    @Test("refresh(): 无 refresh token 抛 noRefreshToken")
    func refreshNoRefreshToken() async throws {
        let kc = InMemoryKeychain()
        let session = GoogleOAuthSession(keychain: kc, presenter: StubPresenter(), tokenExchange: stubExchange)
        try session.saveConfig(GoogleOAuthConfig(
            clientID: "cid", clientSecret: "csec",
            redirectURI: "muses:/oauth", scopes: []))
        // 仅 access token,无 refresh。
        try session.storeTokens(OAuthTokenSet(
            accessToken: "a", refreshToken: nil,
            expiresAt: Date().addingTimeInterval(3600), scope: nil))
        await #expect(throws: OAuthError.noRefreshToken) {
            _ = try await session.refresh()
        }
    }

    // MARK: - Data API parsing (stub http)

    @Test("DataAPI: channel() 解析 snippet.title;subscriptions 解析 resourceId.channelId")
    func dataApiChannelAndSubs() async throws {
        let client = YouTubeDataAPIClient(
            accessTokenProvider: { "AT" },
            http: { req in
                let url = req.url?.absoluteString ?? ""
                if url.contains("/channels") {
                    let body = #"{"items":[{"id":"UC1","snippet":{"title":"Me","thumbnails":{"default":{"url":"u"},"high":{"url":"h"}}}}]}"#
                    return (Data(body.utf8), Self.http200())
                }
                if url.contains("/subscriptions") {
                    let body = #"{"items":[{"snippet":{"title":"Artist X","resourceId":{"channelId":"UCX"}}}]}"#
                    return (Data(body.utf8), Self.http200())
                }
                return (Data("{}".utf8), Self.http200())
            })
        let ch = try await client.channel()
        #expect(ch.id == "UC1")
        #expect(ch.title == "Me")
        #expect(ch.thumbnailURL == "h")
        let subs = try await client.subscriptions()
        #expect(subs.first?.channelId == "UCX")
        #expect(subs.first?.title == "Artist X")
    }

    @Test("DataAPI: likedVideos 解析 channelTitle;myPlaylists 解析 itemCount")
    func dataApiLikedAndPlaylists() async throws {
        let client = YouTubeDataAPIClient(
            accessTokenProvider: { "AT" },
            http: { req in
                let url = req.url?.absoluteString ?? ""
                if url.contains("/videos") {
                    let body = #"{"items":[{"id":"v1","snippet":{"title":"Song","channelTitle":"Artist Y"}}]}"#
                    return (Data(body.utf8), Self.http200())
                }
                if url.contains("/playlists") {
                    let body = #"{"items":[{"id":"PL1","snippet":{"title":"Mix"},"contentDetails":{"itemCount":7}}]}"#
                    return (Data(body.utf8), Self.http200())
                }
                return (Data("{}".utf8), Self.http200())
            })
        let liked = try await client.likedVideos()
        #expect(liked.first?.channelTitle == "Artist Y")
        let pls = try await client.myPlaylists()
        #expect(pls.first?.itemCount == 7)
    }

    @Test("DataAPI: playlistItems 解析 playlistItemId;insert 发送 POST")
    func dataApiPlaylistWrite() async throws {
        let client = YouTubeDataAPIClient(
            accessTokenProvider: { "AT" },
            http: { req in
                let url = req.url?.absoluteString ?? ""
                if req.httpMethod == "POST" {
                    #expect(url.contains("/playlistItems"))
                    let body = #"{"id":"PLI1"}"#
                    return (Data(body.utf8), Self.http200())
                }
                if url.contains("/playlistItems") {
                    let body = #"{"items":[{"id":"PLI1","snippet":{"title":"Song","channelTitle":"A"},"contentDetails":{"videoId":"vid1"}}]}"#
                    return (Data(body.utf8), Self.http200())
                }
                return (Data("{}".utf8), Self.http200())
            })
        let items = try await client.playlistItems(playlistId: "PL1")
        #expect(items.first?.playlistItemId == "PLI1")
        #expect(items.first?.videoId == "vid1")
        let inserted = try await client.insertPlaylistItem(playlistId: "PL1", videoId: "vid2")
        #expect(inserted == "PLI1")
        let writer = YouTubePlaylistWriteService(client: client)
        try await writer.addVideo(playlistId: "PL1", videoId: "vid2")
    }

    @Test("DataAPI: 401 → unauthorized;分页合并两页")
    func dataApiUnauthorizedAndPaging() async throws {
        let client = YouTubeDataAPIClient(
            accessTokenProvider: { "AT" },
            http: { req in
                let url = req.url?.absoluteString ?? ""
                if url.contains("/videos") {
                    return (Data("{}".utf8), Self.http401())
                }
                if url.contains("/subscriptions") {
                    if url.contains("pageToken=P2") {
                        let body = #"{"items":[{"snippet":{"title":"B","resourceId":{"channelId":"CB"}}}]}"#
                        return (Data(body.utf8), Self.http200())
                    }
                    let body = #"{"items":[{"snippet":{"title":"A","resourceId":{"channelId":"CA"}}}],"nextPageToken":"P2"}"#
                    return (Data(body.utf8), Self.http200())
                }
                return (Data("{}".utf8), Self.http200())
            },
            maxPages: 3)
        await #expect(throws: YouTubeDataAPIClient.DataAPIError.unauthorized) {
            _ = try await client.likedVideos()
        }
        let subs = try await client.subscriptions()
        #expect(subs.count == 2)
        #expect(subs.map(\.title) == ["A", "B"])
    }

    // MARK: - AccountService.refresh() 分项失败 + 信号派生

    @Test("AccountService: refresh 分项失败容忍;unauthorized → 断开;signals 派生去重")
    func accountRefreshTolerance() async throws {
        let kc = InMemoryKeychain()
        let session = GoogleOAuthSession(keychain: kc, presenter: StubPresenter(), tokenExchange: stubExchange)
        try session.saveConfig(GoogleOAuthConfig(
            clientID: "cid", clientSecret: "csec",
            redirectURI: "muses:/oauth", scopes: []))
        // 预置令牌(refresh token 存在 → isConnected)。
        try session.storeTokens(OAuthTokenSet(
            accessToken: "AT", refreshToken: "RT",
            expiresAt: Date().addingTimeInterval(3600),
            scope: GoogleOAuthConfig.readOnlyScope))
        let account = YouTubeAccountService(session: session, clientFactory: { sess in
            YouTubeDataAPIClient(accessTokenProvider: { [weak sess] in
                try await sess?.validAccessToken() ?? "AT"
            }, http: { req in
                let url = req.url?.absoluteString ?? ""
                if url.contains("/channels") {
                    let body = #"{"items":[{"id":"UC1","snippet":{"title":"Me"}}]}"#
                    return (Data(body.utf8), Self.http200())
                }
                if url.contains("/subscriptions") {
                    let body = #"{"items":[{"snippet":{"title":"Artist A","resourceId":{"channelId":"CA"}}},{"snippet":{"title":"artist a","resourceId":{"channelId":"CB"}}}]}"#
                    return (Data(body.utf8), Self.http200())
                }
                if url.contains("/videos") {
                    let body = #"{"items":[{"id":"v1","snippet":{"title":"S","channelTitle":"Artist B"}}]}"#
                    return (Data(body.utf8), Self.http200())
                }
                // playlists 失败(返回 500)→ 该项降级,不影响其它。
                return (Data("err".utf8), Self.http500())
            })
        })
        #expect(account.isConnected == true)
        await account.refresh()
        #expect(account.isConnected == true)
        #expect(account.account?.channel?.title == "Me")
        #expect(account.account?.subscriptions.count == 2)
        #expect(account.account?.playlists.isEmpty == true) // playlists 失败降级
        let signals = account.signals()
        #expect(signals != nil)
        // 订阅去重(case-insensitive):"Artist A" 与 "artist a" 合并为一。
        #expect(signals?.subscribedChannelNames.count == 1)
        #expect(signals?.likedArtistNames == ["Artist B"])
    }

    @Test("AccountService: 持久 token 重启后自动刷新账号快照")
    func persistedTokenRestartRehydratesAccount() async throws {
        let kc = InMemoryKeychain()
        let originalSession = GoogleOAuthSession(
            keychain: kc,
            presenter: StubPresenter(),
            tokenExchange: stubExchange
        )
        try originalSession.saveConfig(GoogleOAuthConfig(
            clientID: "cid",
            clientSecret: "csec",
            redirectURI: "muses:/oauth",
            scopes: []
        ))
        try originalSession.storeTokens(OAuthTokenSet(
            accessToken: "persisted-access",
            refreshToken: "persisted-refresh",
            expiresAt: Date().addingTimeInterval(3_600),
            scope: GoogleOAuthConfig.readOnlyScope
        ))

        // A fresh session/service pair models the next app process while using
        // the same Keychain contents.
        let restartedSession = GoogleOAuthSession(
            keychain: kc,
            presenter: StubPresenter(),
            tokenExchange: stubExchange
        )
        let restarted = YouTubeAccountService(
            session: restartedSession,
            clientFactory: { _ in
                YouTubeDataAPIClient(accessTokenProvider: { "persisted-access" }, http: { request in
                    if request.url?.path.contains("/channels") == true {
                        let body = #"{"items":[{"id":"UC-restarted","snippet":{"title":"Restored Account"}}]}"#
                        return (Data(body.utf8), Self.http200())
                    }
                    return (Data(#"{"items":[]}"#.utf8), Self.http200())
                })
            }
        )

        #expect(restarted.isConnected)
        #expect(restarted.account == nil)

        await restarted.refreshPersistedConnectionIfNeeded()

        #expect(restarted.isConnected)
        #expect(restarted.account?.channel?.title == "Restored Account")
        #expect(restarted.lastError == nil)
    }

    @Test("AccountService: refresh 遇 unauthorized → 断开连接")
    func accountRefreshUnauthorizedDisconnects() async throws {
        let kc = InMemoryKeychain()
        let session = GoogleOAuthSession(keychain: kc, presenter: StubPresenter(), tokenExchange: stubExchange)
        try session.saveConfig(GoogleOAuthConfig(
            clientID: "cid", clientSecret: "csec",
            redirectURI: "muses:/oauth", scopes: []))
        try session.storeTokens(OAuthTokenSet(
            accessToken: "AT", refreshToken: "RT",
            expiresAt: Date().addingTimeInterval(3600),
            scope: GoogleOAuthConfig.readOnlyScope))
        let account = YouTubeAccountService(session: session, clientFactory: { _ in
            YouTubeDataAPIClient(accessTokenProvider: { "AT" }, http: { _ in
                (Data("{}".utf8), Self.http401())
            })
        })
        await account.refresh()
        #expect(account.isConnected == false)
        #expect(account.account == nil)
    }

    @Test("AccountService: 无快照 → signals() 返回 nil")
    func signalsNilWithoutSnapshot() {
        let account = YouTubeAccountService()
        #expect(account.signals() == nil)
    }

    // MARK: - HomeDiscoveryInput.enriched 信号合并

    @Test("enriched: 合并去重保序,限 5;top←liked,liked←subs")
    func enrichedMerge() {
        let base = HomeDiscoveryInput(
            topArtistNames: ["LocalA"],
            recentlyPlayedArtistNames: ["Recent"],
            likedArtistNames: ["LocalB"],
            timeBand: .evening, hour: 19, scope: .guest)
        let signals = PersonalizationSignals(
            likedArtistNames: ["LocalA", "YTA", "YTB"],
            subscribedChannelNames: ["LocalB", "Sub1", "Sub2"],
            playlistTitles: ["PL"])
        let enriched = base.enriched(with: signals)
        // top: LocalA + YTA + YTB (去重 LocalA 已存在则不重复加)。
        #expect(enriched.topArtistNames == ["LocalA", "YTA", "YTB"])
        // liked: LocalB + Sub1 + Sub2。
        #expect(enriched.likedArtistNames == ["LocalB", "Sub1", "Sub2"])
        // 不变字段。
        #expect(enriched.recentlyPlayedArtistNames == ["Recent"])
        #expect(enriched.timeBand == .evening)
        #expect(enriched.hour == 19)
    }

    @Test("enriched: 合并上限 5")
    func enrichedLimit5() {
        let base = HomeDiscoveryInput(
            topArtistNames: [], recentlyPlayedArtistNames: [],
            likedArtistNames: [], timeBand: .morning, hour: 8, scope: .guest)
        let signals = PersonalizationSignals(
            likedArtistNames: ["a", "b", "c", "d", "e", "f", "g"],
            subscribedChannelNames: [], playlistTitles: [])
        let enriched = base.enriched(with: signals)
        #expect(enriched.topArtistNames.count == 5)
    }

    // MARK: - stubs

    private nonisolated static func http200() -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
    private nonisolated static func http401() -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
    }
    private nonisolated static func http500() -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 500, httpVersion: nil, headerFields: nil)!
    }

    private nonisolated var stubExchange: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
        { _ in
            let body = #"{"access_token":"AT","refresh_token":"RT","expires_in":3600,"scope":"youtube.readonly"}"#
            return (Data(body.utf8), Self.http200())
        }
    }
}

/// 授权页呈现桩:从授权 URL 解析 state,构造含 code + 匹配 state 的回调 URL。
/// `returnsURL=false` 模拟用户取消(返回 nil)。
@MainActor
final class StubPresenter: AuthSessionPresenting, @unchecked Sendable {
    let returnsURL: Bool
    private(set) var lastAuthURL: URL?
    init(returnsURL: Bool = true) { self.returnsURL = returnsURL }

    func present(authURL: URL, callbackScheme: String) async -> URL? {
        lastAuthURL = authURL
        guard returnsURL else { return nil }
        let comps = URLComponents(url: authURL, resolvingAgainstBaseURL: false)
        let state = comps?.queryItems?.first(where: { $0.name == "state" })?.value ?? ""
        return URL(string: "muses:/oauth?code=AUTH_CODE&state=\(state)")
    }
}
