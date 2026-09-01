import Foundation
import Security
import CryptoKit
import AuthenticationServices
import AppKit
import Network

/// Application-owned Google Desktop OAuth configuration.
///
/// Production builds inject the client identifier into Info.plist. Local
/// developer runs may use environment variables. Installed-app client secrets
/// are not secrets and are optional; end users never edit this configuration.
struct GoogleOAuthConfig: Codable, Sendable, Equatable {
    let clientID: String
    let clientSecret: String
    /// Loopback redirect registered by the Muses OAuth desktop client.
    let redirectURI: String
    /// Requested OAuth scopes (empty -> least-privilege read-only access).
    let scopes: [String]

    static let readOnlyScope = "https://www.googleapis.com/auth/youtube.readonly"
    static let manageScope = "https://www.googleapis.com/auth/youtube"
    static let defaultScopes = [readOnlyScope]

    var isValid: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !redirectURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func applicationOwned(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GoogleOAuthConfig? {
        let info = bundle.infoDictionary ?? [:]
        let clientID = environment["MUSES_GOOGLE_OAUTH_CLIENT_ID"]
            ?? info["MusesGoogleOAuthClientID"] as? String
            ?? ""
        let clientSecret = environment["MUSES_GOOGLE_OAUTH_CLIENT_SECRET"]
            ?? info["MusesGoogleOAuthClientSecret"] as? String
            ?? ""
        let redirectURI = environment["MUSES_GOOGLE_OAUTH_REDIRECT_URI"]
            ?? info["MusesGoogleOAuthRedirectURI"] as? String
            ?? "http://127.0.0.1:53682/"
        let config = GoogleOAuthConfig(
            clientID: clientID,
            clientSecret: clientSecret,
            redirectURI: redirectURI,
            scopes: defaultScopes
        )
        return config.isValid && config.isLoopbackRedirect ? config : nil
    }

    /// Default redirect scheme (used to intercept ASWebAuthenticationSession redirects).
    var redirectScheme: String {
        if let scheme = URL(string: redirectURI)?.scheme, !scheme.isEmpty { return scheme }
        // Fallback: a custom scheme such as "muses".
        return "muses"
    }

    /// Google Desktop clients use loopback (`http://127.0.0.1` / `localhost`), not custom schemes.
    var isLoopbackRedirect: Bool {
        guard let url = URL(string: redirectURI) else { return false }
        let scheme = (url.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https" else { return false }
        let host = (url.host ?? "").lowercased()
        return host == "127.0.0.1" || host == "localhost"
    }

    var loopbackPort: UInt16 {
        UInt16(URL(string: redirectURI)?.port ?? 53682)
    }
}

/// OAuth token set (Keychain account "tokens"). `expiresAt` is derived from `expires_in`.
struct OAuthTokenSet: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
    let scope: String?

    /// Treats tokens as expired 60s early to avoid using a stale one at the boundary.
    var isAccessExpired: Bool { Date().addingTimeInterval(60) >= expiresAt }
}

enum OAuthError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case userCancelled
    case authFailed(String)          // redirect missing a code, or state mismatch
    case tokenExchangeFailed(String) // token endpoint non-200 or parse failure
    case noRefreshToken
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            tr("This Muses build is missing its YouTube sign-in configuration", "此 Muses 构建缺少 YouTube 登录配置")
        case .userCancelled:
            tr("Sign-in cancelled", "用户取消登录")
        case .authFailed(let m):
            tr("OAuth authorization failed: \(m)", "OAuth 授权失败:\(m)")
        case .tokenExchangeFailed(let m):
            tr("OAuth token exchange failed: \(m)", "OAuth 令牌交换失败:\(m)")
        case .noRefreshToken:
            tr("No refresh token; sign in again", "无 refresh token,无法刷新(需重新登录)")
        case .network(let m):
            tr("Network error: \(m)", "网络错误:\(m)")
        }
    }

    static func == (lhs: OAuthError, rhs: OAuthError) -> Bool {
        String(describing: lhs) == String(describing: rhs)
    }
}

/// Abstraction for presenting the authorization page (real implementation uses ASWebAuthenticationSession; tests inject fakes).
/// Methods are @MainActor: ASWebAuthenticationSession must be presented on the main thread.
protocol AuthSessionPresenting: Sendable {
    /// Presents the authorization URL and intercepts the `callbackScheme` redirect, returning its URL (code/state included).
    @MainActor func present(authURL: URL, callbackScheme: String) async -> URL?
}

/// Real ASWebAuthenticationSession presenter (macOS).
/// Uses the main window as the presentation context; returns nil on failure/cancel.
final class ASWebAuthPresenter: AuthSessionPresenting, @unchecked Sendable {
    @MainActor func present(authURL: URL, callbackScheme: String) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            let session = ASWebAuthenticationSession(url: authURL,
                                                    callbackURLScheme: callbackScheme) { url, _ in
                cont.resume(returning: url)
            }
            session.presentationContextProvider = AuthPresentationProvider.shared
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                cont.resume(returning: nil)
            }
        }
    }
}

@MainActor
final class AuthPresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthPresentationProvider()
    func presentationAnchor(for session: ASWebAuthenticationSession)
        -> ASPresentationAnchor {
        NSApplication.shared.windows.first { $0.isKeyWindow }
            ?? NSApplication.shared.windows.first
            ?? ASPresentationAnchor()
    }
}

/// Google OAuth 2.0 PKCE session: authorization-code flow + token refresh, with tokens in the Keychain.
/// `@MainActor` for easy UI state binding; token network exchanges go through the injected `tokenExchange` closure (replaceable in tests).
@MainActor
final class GoogleOAuthSession {
    static let configAccount = "config"
    static let tokensAccount = "tokens"

    private let keychain: KeychainStoring
    private let presenter: AuthSessionPresenting
    private let tokenExchange: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let configProvider: @Sendable () -> GoogleOAuthConfig?

    init(keychain: KeychainStoring,
         presenter: AuthSessionPresenting = ASWebAuthPresenter(),
         configProvider: @escaping @Sendable () -> GoogleOAuthConfig? = {
            GoogleOAuthConfig.applicationOwned()
         },
         tokenExchange: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OAuthError.network("Not an HTTP response")
            }
            return (data, http)
         }) {
        self.keychain = keychain
        self.presenter = presenter
        self.configProvider = configProvider
        self.tokenExchange = tokenExchange
    }

    // MARK: - Config

    func loadConfig() -> GoogleOAuthConfig? {
        if let applicationConfig = configProvider(), applicationConfig.isValid {
            return applicationConfig
        }
        // One-release compatibility for existing development installs. The UI
        // no longer exposes this value and production builds use app config.
        guard let data = keychain.data(for: Self.configAccount) else { return nil }
        return try? JSONDecoder().decode(GoogleOAuthConfig.self, from: data)
    }

    /// Test/development compatibility. Product UI never calls this method.
    func saveConfig(_ config: GoogleOAuthConfig) throws {
        guard config.isValid else { throw OAuthError.notConfigured }
        let data = try JSONEncoder().encode(config)
        guard keychain.set(data, for: Self.configAccount) else {
            throw OAuthError.tokenExchangeFailed("Keychain write failed")
        }
    }

    func clearConfig() {
        _ = keychain.delete(Self.configAccount)
    }

    // MARK: - Connect / disconnect

    /// Whether a refresh token is held (i.e. refreshable — the "connected" state).
    var isConnected: Bool {
        loadTokens()?.refreshToken != nil
    }

    /// Starts the authorization-code + PKCE flow and stores tokens on success. Throws on cancel or failure.
    func connect(requestedScopes: [String]? = nil,
                 includeGrantedScopes: Bool = true) async throws {
        guard let config = loadConfig() else { throw OAuthError.notConfigured }
        let verifier = Self.generateCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.generateCodeVerifier()
        let configuredScopes = config.scopes.isEmpty
            ? GoogleOAuthConfig.defaultScopes : config.scopes
        let scopes = requestedScopes ?? configuredScopes
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "include_granted_scopes",
                  value: includeGrantedScopes ? "true" : "false"),
            .init(name: "prompt", value: "consent")
        ]
        guard let authURL = components.url else { throw OAuthError.authFailed("Failed to build the authorization URL") }

        let callback: URL
        if config.isLoopbackRedirect {
            let server = LoopbackCallbackServer()
            async let accepted = server.listen(port: config.loopbackPort)
            NSWorkspace.shared.open(authURL)
            guard let url = await accepted else { throw OAuthError.userCancelled }
            callback = url
        } else {
            guard let url = await presenter.present(
                authURL: authURL, callbackScheme: config.redirectScheme) else {
                throw OAuthError.userCancelled
            }
            callback = url
        }
        // Parse code / state.
        let cbComps = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        let items = cbComps?.queryItems ?? []
        let returnedState = items.first(where: { $0.name == "state" })?.value
        guard returnedState == state else { throw OAuthError.authFailed("State mismatch") }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            let err = items.first(where: { $0.name == "error" })?.value ?? "missing code"
            throw OAuthError.authFailed(err)
        }
        try await exchangeCode(code, verifier: verifier, config: config)
    }

    /// Exchanges the authorization code for tokens and stores them in the Keychain.
    private func exchangeCode(_ code: String,
                              verifier: String,
                              config: GoogleOAuthConfig) async throws {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = [
            "code": code,
            "client_id": config.clientID,
            "redirect_uri": config.redirectURI,
            "code_verifier": verifier,
            "grant_type": "authorization_code"
        ]
        if !config.clientSecret.isEmpty { body["client_secret"] = config.clientSecret }
        req.httpBody = Self.percentEncoded(body).data(using: .utf8)

        let (data, resp) = try await send(req)
        guard resp.statusCode == 200 else {
            throw OAuthError.tokenExchangeFailed("HTTP \(resp.statusCode): \(Self.truncate(data))")
        }
        let parsed = try? JSONDecoder().decode(TokenResponse.self, from: data)
        guard let p = parsed, !p.accessToken.isEmpty else {
            throw OAuthError.tokenExchangeFailed("Failed to parse tokens")
        }
        let existing = loadTokens()
        let tokens = OAuthTokenSet(
            accessToken: p.accessToken,
            refreshToken: p.refreshToken ?? existing?.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(p.expiresIn)),
            // Capabilities are derived only from scopes returned by Google.
            // A missing scope never silently upgrades permissions.
            scope: p.scope ?? existing?.scope)
        try storeTokens(tokens)
    }

    /// Refreshes the access token; throws without a refresh token. Returns the new valid access token.
    func refresh() async throws -> String {
        guard let config = loadConfig() else { throw OAuthError.notConfigured }
        guard let existing = loadTokens(), let refresh = existing.refreshToken else {
            throw OAuthError.noRefreshToken
        }
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = [
            "client_id": config.clientID,
            "refresh_token": refresh,
            "grant_type": "refresh_token"
        ]
        if !config.clientSecret.isEmpty { body["client_secret"] = config.clientSecret }
        req.httpBody = Self.percentEncoded(body).data(using: .utf8)
        let (data, resp) = try await send(req)
        guard resp.statusCode == 200 else {
            throw OAuthError.tokenExchangeFailed("HTTP \(resp.statusCode): \(Self.truncate(data))")
        }
        let parsed = try? JSONDecoder().decode(TokenResponse.self, from: data)
        guard let p = parsed, !p.accessToken.isEmpty else {
            throw OAuthError.tokenExchangeFailed("Failed to parse refreshed tokens")
        }
        // Google's refresh response usually omits a new refresh_token; keep the old one.
        let tokens = OAuthTokenSet(
            accessToken: p.accessToken,
            refreshToken: p.refreshToken ?? existing.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(p.expiresIn)),
            scope: p.scope ?? existing.scope)
        try storeTokens(tokens)
        return tokens.accessToken
    }

    /// Returns a valid access token, refreshing automatically when expired.
    func validAccessToken() async throws -> String {
        if let t = loadTokens(), !t.isAccessExpired { return t.accessToken }
        return try await refresh()
    }

    /// Disconnect: clears tokens (the OAuth client configuration is kept).
    func disconnect() {
        _ = keychain.delete(Self.tokensAccount)
    }

    // MARK: - Token store

    func loadTokens() -> OAuthTokenSet? {
        guard let data = keychain.data(for: Self.tokensAccount) else { return nil }
        return try? JSONDecoder().decode(OAuthTokenSet.self, from: data)
    }

    func storeTokens(_ tokens: OAuthTokenSet) throws {
        let data = try JSONEncoder().encode(tokens)
        guard keychain.set(data, for: Self.tokensAccount) else {
            throw OAuthError.tokenExchangeFailed(tr("Keychain write failed", "Keychain 写入失败"))
        }
    }

    // MARK: - Internal

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await tokenExchange(req)
        } catch let e as OAuthError {
            throw e
        } catch {
            throw OAuthError.network(error.localizedDescription)
        }
    }

    // MARK: - PKCE / encoding helpers (pure, testable)

    /// 43 random bytes, base64url-encoded without padding, used as the code_verifier.
    nonisolated static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    /// S256 code_challenge:SHA256(verifier) base64url。
    nonisolated static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncodedString()
    }

    nonisolated static func percentEncoded(_ pairs: [String: String]) -> String {
        let allowed = CharacterSet.urlQueryAllowed
        return pairs.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
    }

    nonisolated static func truncate(_ data: Data, maxLength: Int = 200) -> String {
        let s = String(data: data, encoding: .utf8) ?? ""
        return s.prefix(maxLength).description
    }
}

/// Token endpoint response (JSON).
struct TokenResponse: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
    }
}

private extension Data {
    /// RFC 4648 base64url (no `=` padding), used for PKCE.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Local HTTP listener for Google Desktop OAuth loopback redirects.
final class LoopbackCallbackServer: @unchecked Sendable {
    private final class ResumeBox: @unchecked Sendable {
        let lock = NSLock()
        var resumed = false
        var listener: NWListener?
        let continuation: CheckedContinuation<URL?, Never>

        init(_ continuation: CheckedContinuation<URL?, Never>) {
            self.continuation = continuation
        }

        func finish(_ url: URL?) {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            listener?.cancel()
            listener = nil
            continuation.resume(returning: url)
        }
    }

    func listen(port: UInt16, timeoutSeconds: TimeInterval = 180) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            let box = ResumeBox(cont)
            do {
                let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
                box.listener = listener
                listener.newConnectionHandler = { conn in
                    conn.start(queue: .main)
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        let first = text.split(separator: "\r\n").first.map(String.init) ?? ""
                        let path = first.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                        let url = URL(string: "http://127.0.0.1:\(port)\(path)")
                        let body = "You can close this window and return to Muses."
                        let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                        conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in
                            conn.cancel()
                            box.finish(url)
                        })
                    }
                }
                listener.stateUpdateHandler = { state in
                    if case .failed = state { box.finish(nil) }
                }
                listener.start(queue: .main)
                DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
                    box.finish(nil)
                }
            } catch {
                box.finish(nil)
            }
        }
    }
}
