import Testing
import Foundation
import CryptoKit
@testable import Muses

private actor RequestRecorder {
    private(set) var values: [URLRequest] = []
    func append(_ request: URLRequest) { values.append(request) }
}

/// YouTube OAuth + Keychain + Data API + personalized-signal merged unit tests.
///
/// All pure logic / injectable stubs; the real Keychain, ASWebAuthenticationSession, and network are never touched.
/// `@MainActor` because `GoogleOAuthSession` / `YouTubeAccountService` are @MainActor (Swift Testing
/// supports annotating the suite with the isolation type).
@MainActor
struct YouTubeOAuthTests {

    // MARK: - Keychain (InMemory)

    @Test("InMemoryKeychain: set/get/delete round trip")
    func keychainRoundtrip() {
        let kc = InMemoryKeychain()
        let payload = Data("secret".utf8)
        #expect(kc.set(payload, for: "a") == true)
        #expect(kc.data(for: "a") == payload)
        #expect(kc.delete("a") == true)
        #expect(kc.data(for: "a") == nil)
    }

    @Test("InMemoryKeychain: overwrite and deleting non-existent key returns true")
    func keychainOverwriteAndMissingDelete() {
        let kc = InMemoryKeychain()
        _ = kc.set(Data([1]), for: "k")
        _ = kc.set(Data([2]), for: "k")
        #expect(kc.data(for: "k") == Data([2]))
        #expect(kc.delete("never") == true)
    }

    // MARK: - OAuth config / tokens

    @Test("GoogleOAuthSession: saveConfig/loadConfig round trip; rejects empty values")
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

    @Test("OAuthTokenSet: isAccessExpired 60s margin")
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

    @Test("PKCE: codeChallenge is reproducible (SHA256 base64url); verifier is unique")
    func pkceDeterministic() {
        let verifier = "test-verifier-12345"
        let ch1 = GoogleOAuthSession.codeChallenge(for: verifier)
        let ch2 = GoogleOAuthSession.codeChallenge(for: verifier)
        #expect(ch1 == ch2)
        // A SHA256 digest is 32 bytes → unpadded base64url is ~43 characters.
        #expect(ch1.contains("=") == false) // base64url, unpadded
        #expect(ch1.contains("+") == false) // base64url uses - _ instead of + /
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

    @Test("Desktop OAuth loopback binds a random port and accepts the first callback")
    func randomLoopbackCallback() async throws {
        let server = LoopbackCallbackServer()
        let redirect = try #require(await server.start())
        let components = try #require(URLComponents(string: redirect))
        let port = try #require(components.port)
        #expect(port > 0)

        var callbackComponents = components
        callbackComponents.queryItems = [
            URLQueryItem(name: "code", value: "callback-code"),
            URLQueryItem(name: "state", value: "callback-state")
        ]
        let callbackURL = try #require(callbackComponents.url)
        let callback = await server.waitForCallback(timeoutSeconds: 2) {
            Task {
                _ = try? await URLSession.shared.data(from: callbackURL)
            }
            return true
        }
        #expect(callback?.query == callbackComponents.query)
    }

    // MARK: - connect() flow (stub presenter + stub token exchange)

    @Test("connect(): successfully stores tokens (refresh token non-empty, isConnected is true)")
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

    @Test("connect(): user cancellation (presenter returns nil) throws userCancelled")
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

    @Test("connect(): unconfigured credentials throws notConfigured")
    func connectNotConfigured() async {
        let kc = InMemoryKeychain()
        let session = GoogleOAuthSession(keychain: kc, presenter: StubPresenter(), tokenExchange: stubExchange)
        await #expect(throws: OAuthError.notConfigured) {
            try await session.connect()
        }
    }

    // MARK: - refresh()

    @Test("refresh(): refreshes token; reuses old refresh_token when missing in response")
    func refreshPreservesRefreshToken() async throws {
        let kc = InMemoryKeychain()
        // Pre-seed stored tokens (including a refresh token).
        let existing = OAuthTokenSet(
            accessToken: "oldAT", refreshToken: "RT",
            expiresAt: Date().addingTimeInterval(-60), scope: "youtube.readonly")
        let session = GoogleOAuthSession(keychain: kc, presenter: StubPresenter(), tokenExchange: { req in
            // Refresh response: a new access token, no refresh_token.
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
        #expect(after?.refreshToken == "RT") // keeps the old refresh token
    }

    @Test("refresh(): missing refresh token throws noRefreshToken")
    func refreshNoRefreshToken() async throws {
        let kc = InMemoryKeychain()
        let session = GoogleOAuthSession(keychain: kc, presenter: StubPresenter(), tokenExchange: stubExchange)
        try session.saveConfig(GoogleOAuthConfig(
            clientID: "cid", clientSecret: "csec",
            redirectURI: "muses:/oauth", scopes: []))
        // Access token only, no refresh token.
        try session.storeTokens(OAuthTokenSet(
            accessToken: "a", refreshToken: nil,
            expiresAt: Date().addingTimeInterval(3600), scope: nil))
        await #expect(throws: OAuthError.noRefreshToken) {
            _ = try await session.refresh()
        }
    }

    @Test("refresh(): invalid_grant is an expired authorization, not a transient exchange failure")
    func refreshInvalidGrant() async throws {
        let kc = InMemoryKeychain()
        let session = GoogleOAuthSession(
            keychain: kc,
            presenter: StubPresenter(),
            tokenExchange: { _ in
                (Data(#"{"error":"invalid_grant","error_description":"Token has been revoked"}"#.utf8),
                 Self.http400())
            }
        )
        try session.saveConfig(GoogleOAuthConfig(
            clientID: "cid", clientSecret: "csec",
            redirectURI: "muses:/oauth", scopes: []))
        try session.storeTokens(OAuthTokenSet(
            accessToken: "expired", refreshToken: "revoked",
            expiresAt: Date().addingTimeInterval(-60),
            scope: GoogleOAuthConfig.readOnlyScope))

        await #expect(throws: OAuthError.authorizationExpired) {
            _ = try await session.refresh()
        }
    }

    // MARK: - Data API parsing (stub http)

    @Test("DataAPI: channel() parses snippet.title; subscriptions parses resourceId.channelId")
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

    @Test("DataAPI: likedVideos parses channelTitle; myPlaylists parses itemCount")
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

    @Test("DataAPI: playlistItems parses playlistItemId; insert sends POST")
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

    @Test("DataAPI: playlist and subscription writes encode explicit resources")
    func dataApiPlaylistAndSubscriptionWrites() async throws {
        let requests = RequestRecorder()
        let client = YouTubeDataAPIClient(
            accessTokenProvider: { "AT" },
            http: { req in
                await requests.append(req)
                let url = req.url?.absoluteString ?? ""
                if url.contains("/playlists") && req.httpMethod == "POST" {
                    return (Data(#"{"id":"PLNEW","snippet":{"title":"New"},"contentDetails":{"itemCount":0}}"#.utf8), Self.http200())
                }
                if url.contains("/subscriptions") && req.httpMethod == "POST" {
                    return (Data(#"{"id":"SUB1"}"#.utf8), Self.http200())
                }
                return (Data("{}".utf8), Self.http200())
            })

        let playlist = try await client.createPlaylist(title: "New", description: "desc", privacy: .unlisted)
        #expect(playlist.id == "PLNEW")
        try await client.deletePlaylist(id: "PLNEW")
        #expect(try await client.subscribe(channelId: "UC1") == "SUB1")
        try await client.unsubscribe(subscriptionId: "SUB1")

        let recorded = await requests.values
        #expect(recorded.count == 4)
        let playlistBody = try #require(recorded[0].httpBody)
        #expect(String(decoding: playlistBody, as: UTF8.self).contains("unlisted"))
        #expect(String(decoding: playlistBody, as: UTF8.self).contains("desc"))
        let subscriptionBody = try #require(recorded[2].httpBody)
        #expect(String(decoding: subscriptionBody, as: UTF8.self).contains("UC1"))
    }

    @Test("DataAPI: 401 maps to unauthorized; pagination merges pages")
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

    // MARK: - AccountService.refresh() partial failures

    @Test("AccountService: refresh tolerates a partial endpoint failure")
    func accountRefreshTolerance() async throws {
        let kc = InMemoryKeychain()
        let session = GoogleOAuthSession(keychain: kc, presenter: StubPresenter(), tokenExchange: stubExchange)
        try session.saveConfig(GoogleOAuthConfig(
            clientID: "cid", clientSecret: "csec",
            redirectURI: "muses:/oauth", scopes: []))
        // Pre-seed tokens (refresh token present → isConnected).
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
                // playlists fails (returns 500) → that item degrades without affecting the others.
                return (Data("err".utf8), Self.http500())
            })
        })
        #expect(account.isConnected == true)
        await account.refresh()
        #expect(account.isConnected == true)
        #expect(account.account?.channel?.title == "Me")
        #expect(account.account?.subscriptions.count == 2)
        #expect(account.account?.likedVideos.map(\.channelTitle) == ["Artist B"])
        #expect(account.account?.playlists.isEmpty == true) // playlists failure degrades gracefully
    }

    @Test("AccountService: persisted token auto-rehydrates account snapshot after restart")
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

    @Test("AccountService: refresh on unauthorized disconnects session")
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
        #expect(account.connectionState == .expired)
        #expect(account.account == nil)
    }

    @Test("AccountService: revoked refresh token becomes recoverable expired state")
    func accountRefreshRevokedTokenExpiresConnection() async throws {
        let kc = InMemoryKeychain()
        let session = GoogleOAuthSession(
            keychain: kc,
            presenter: StubPresenter(),
            tokenExchange: { _ in
                (Data(#"{"error":"invalid_grant"}"#.utf8), Self.http400())
            }
        )
        try session.saveConfig(GoogleOAuthConfig(
            clientID: "cid", clientSecret: "csec",
            redirectURI: "muses:/oauth", scopes: []))
        try session.storeTokens(OAuthTokenSet(
            accessToken: "expired", refreshToken: "revoked",
            expiresAt: Date().addingTimeInterval(-60),
            scope: GoogleOAuthConfig.readOnlyScope))
        let account = YouTubeAccountService(session: session)

        await account.refresh()

        #expect(!account.isConnected)
        #expect(account.connectionState == .expired)
        #expect(account.account == nil)
        #expect(!session.isConnected)
        #expect(account.lastError == OAuthError.authorizationExpired.errorDescription)
    }

    // MARK: - stubs

    private nonisolated static func http200() -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
    private nonisolated static func http400() -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 400, httpVersion: nil, headerFields: nil)!
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

/// Authorization-page stub: parses state from the authorization URL and builds a callback URL containing code + the matching state.
/// `returnsURL = false` simulates the user cancelling (returns nil).
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
