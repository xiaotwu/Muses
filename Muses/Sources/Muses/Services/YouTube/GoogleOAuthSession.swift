import Foundation
import Security
import CryptoKit
import AuthenticationServices

/// Google OAuth 客户端配置(用户在 Google Cloud Console 创建 Desktop OAuth 客户端后填入)。
/// 存 Keychain(account "config"),不写 UserDefaults/明文(spec §4)。
struct GoogleOAuthConfig: Codable, Sendable, Equatable {
    let clientID: String
    let clientSecret: String
    /// 重定向 URI,需与 Google Console 一致。macOS 桌面端用自定义 scheme,如 "muses:/oauth"。
    let redirectURI: String
    /// 请求的 scope 列表(空则用默认 youtube.readonly)。
    let scopes: [String]

    static let defaultScopes = ["https://www.googleapis.com/auth/youtube.readonly"]

    var isValid: Bool {
        !clientID.isEmpty && !clientSecret.isEmpty && !redirectURI.isEmpty
    }

    /// 默认重定向 scheme(用于 ASWebAuthenticationSession 拦截)。
    var redirectScheme: String {
        if let scheme = URL(string: redirectURI)?.scheme, !scheme.isEmpty { return scheme }
        // 回退:取 "muses" 这类自定义 scheme。
        return "muses"
    }
}

/// OAuth 令牌集合(存 Keychain account "tokens")。`expiresAt` 由 `expires_in` 计算得来。
struct OAuthTokenSet: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
    let scope: String?

    /// 提前 60s 视为过期,避免边界用错令牌。
    var isAccessExpired: Bool { Date().addingTimeInterval(60) >= expiresAt }
}

enum OAuthError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case userCancelled
    case authFailed(String)          // 重定向缺少 code / state 不匹配
    case tokenExchangeFailed(String) // token 端点非 200 或解析失败
    case noRefreshToken
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "未配置 YouTube OAuth(Client ID/Secret/重定向)"
        case .userCancelled: "用户取消登录"
        case .authFailed(let m): "OAuth 授权失败:\(m)"
        case .tokenExchangeFailed(let m): "OAuth 令牌交换失败:\(m)"
        case .noRefreshToken: "无 refresh token,无法刷新(需重新登录)"
        case .network(let m): "网络错误:\(m)"
        }
    }

    static func == (lhs: OAuthError, rhs: OAuthError) -> Bool {
        String(describing: lhs) == String(describing: rhs)
    }
}

/// 授权页呈现抽象(真实实现用 ASWebAuthenticationSession;测试注入伪造)。
/// 方法为 @MainActor:ASWebAuthenticationSession 必须在主线程呈现。
protocol AuthSessionPresenting: Sendable {
    /// 呈现授权 URL,拦截 `callbackScheme` 的重定向并返回其 URL(含 code/state)。
    @MainActor func present(authURL: URL, callbackScheme: String) async -> URL?
}

/// 真实 ASWebAuthenticationSession 呈现者(macOS)。
/// 用主窗口作为 presentation context;失败/取消返回 nil。
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

/// Google OAuth 2.0 PKCE 会话:授权码流程 + 令牌刷新,令牌存 Keychain。
/// `@MainActor` 便于 UI 状态绑定;令牌网络交换经注入的 `tokenExchange` 闭包(测试可替换)。
@MainActor
final class GoogleOAuthSession {
    static let configAccount = "config"
    static let tokensAccount = "tokens"

    private let keychain: KeychainStoring
    private let presenter: AuthSessionPresenting
    private let tokenExchange: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(keychain: KeychainStoring,
         presenter: AuthSessionPresenting = ASWebAuthPresenter(),
         tokenExchange: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OAuthError.network("非 HTTP 响应")
            }
            return (data, http)
         }) {
        self.keychain = keychain
        self.presenter = presenter
        self.tokenExchange = tokenExchange
    }

    // MARK: - Config

    func loadConfig() -> GoogleOAuthConfig? {
        guard let data = keychain.data(for: Self.configAccount) else { return nil }
        return try? JSONDecoder().decode(GoogleOAuthConfig.self, from: data)
    }

    /// 存 OAuth 客户端配置(Settings 页填入)。空值会被拒绝。
    func saveConfig(_ config: GoogleOAuthConfig) throws {
        guard config.isValid else { throw OAuthError.notConfigured }
        let data = try JSONEncoder().encode(config)
        guard keychain.set(data, for: Self.configAccount) else {
            throw OAuthError.tokenExchangeFailed("Keychain 写入失败")
        }
    }

    func clearConfig() {
        _ = keychain.delete(Self.configAccount)
    }

    // MARK: - Connect / disconnect

    /// 当前是否持有 refresh token(即可刷新,即"已连接")。
    var isConnected: Bool {
        loadTokens()?.refreshToken != nil
    }

    /// 发起授权码 + PKCE 流程,成功后存令牌。用户取消或失败抛错。
    func connect() async throws {
        guard let config = loadConfig() else { throw OAuthError.notConfigured }
        let verifier = Self.generateCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.generateCodeVerifier()
        let scopes = config.scopes.isEmpty ? GoogleOAuthConfig.defaultScopes : config.scopes
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
            .init(name: "prompt", value: "consent")
        ]
        guard let authURL = components.url else { throw OAuthError.authFailed("构造授权 URL 失败") }

        guard let callback = await presenter.present(
            authURL: authURL, callbackScheme: config.redirectScheme) else {
            throw OAuthError.userCancelled
        }
        // 解析 code / state。
        let cbComps = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        let items = cbComps?.queryItems ?? []
        let returnedState = items.first(where: { $0.name == "state" })?.value
        guard returnedState == state else { throw OAuthError.authFailed("state 不匹配") }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            let err = items.first(where: { $0.name == "error" })?.value ?? "缺 code"
            throw OAuthError.authFailed(err)
        }
        try await exchangeCode(code, verifier: verifier, config: config)
    }

    /// 用授权码交换令牌并存 Keychain。
    private func exchangeCode(_ code: String,
                              verifier: String,
                              config: GoogleOAuthConfig) async throws {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "code": code,
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "redirect_uri": config.redirectURI,
            "code_verifier": verifier,
            "grant_type": "authorization_code"
        ]
        req.httpBody = Self.percentEncoded(body).data(using: .utf8)

        let (data, resp) = try await send(req)
        guard resp.statusCode == 200 else {
            throw OAuthError.tokenExchangeFailed("HTTP \(resp.statusCode): \(Self.truncate(data))")
        }
        let parsed = try? JSONDecoder().decode(TokenResponse.self, from: data)
        guard let p = parsed, !p.accessToken.isEmpty else {
            throw OAuthError.tokenExchangeFailed("解析令牌失败")
        }
        let tokens = OAuthTokenSet(
            accessToken: p.accessToken,
            refreshToken: p.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(p.expiresIn)),
            scope: p.scope)
        try storeTokens(tokens)
    }

    /// 刷新 access token;无 refresh token 抛错。返回新的有效 access token。
    func refresh() async throws -> String {
        guard let config = loadConfig() else { throw OAuthError.notConfigured }
        guard let existing = loadTokens(), let refresh = existing.refreshToken else {
            throw OAuthError.noRefreshToken
        }
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "refresh_token": refresh,
            "grant_type": "refresh_token"
        ]
        req.httpBody = Self.percentEncoded(body).data(using: .utf8)
        let (data, resp) = try await send(req)
        guard resp.statusCode == 200 else {
            throw OAuthError.tokenExchangeFailed("HTTP \(resp.statusCode): \(Self.truncate(data))")
        }
        let parsed = try? JSONDecoder().decode(TokenResponse.self, from: data)
        guard let p = parsed, !p.accessToken.isEmpty else {
            throw OAuthError.tokenExchangeFailed("解析刷新令牌失败")
        }
        // Google 刷新响应通常不返回新 refresh_token,沿用旧的。
        let tokens = OAuthTokenSet(
            accessToken: p.accessToken,
            refreshToken: p.refreshToken ?? existing.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(p.expiresIn)),
            scope: p.scope ?? existing.scope)
        try storeTokens(tokens)
        return tokens.accessToken
    }

    /// 返回有效 access token;若过期则自动刷新。
    func validAccessToken() async throws -> String {
        if let t = loadTokens(), !t.isAccessExpired { return t.accessToken }
        return try await refresh()
    }

    /// 断开连接:清除令牌(保留 OAuth 客户端配置)。
    func disconnect() {
        _ = keychain.delete(Self.tokensAccount)
    }

    // MARK: - Token store

    func loadTokens() -> OAuthTokenSet? {
        guard let data = keychain.data(for: Self.tokensAccount) else { return nil }
        return try? JSONDecoder().decode(OAuthTokenSet.self, from: data)
    }

    @discardableResult
    func storeTokens(_ tokens: OAuthTokenSet) throws -> Bool {
        let data = try JSONEncoder().encode(tokens)
        return keychain.set(data, for: Self.tokensAccount)
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

    /// 随机 43 字节 base64url 编码(无填充),作为 code_verifier。
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

/// token 端点响应(JSON)。
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
    /// RFC 4648 base64url(无 `=` 填充),用于 PKCE。
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}