import Foundation
import CryptoKit
import MusesWebHomeProtocol

struct WebHomeTransportResponse: Sendable {
    let data: Data
    let statusCode: Int
    let finalURL: URL?
}

protocol WebHomeTransport: Sendable {
    func data(for request: URLRequest) async throws -> WebHomeTransportResponse
}

final class URLSessionWebHomeTransport: WebHomeTransport, @unchecked Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> WebHomeTransportResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebHomeCoreError.code(.malformedResponse)
        }
        return WebHomeTransportResponse(
            data: data,
            statusCode: http.statusCode,
            finalURL: http.url)
    }
}

struct WebHomeBootstrapContext: Sendable, Equatable {
    let apiKey: String
    let clientVersion: String
    let visitorData: String
    let locale: String
    let region: String
}

struct WebHomeSessionResult: Sendable {
    let context: WebHomeBootstrapContext
    let channelID: String
    let payload: Data?
}

struct WebHomeBootstrapParser: Sendable {
    func parse(html: Data, locale: String, region: String) throws -> WebHomeBootstrapContext {
        guard html.count <= 5 * 1024 * 1024,
              let string = String(data: html, encoding: .utf8) else {
            throw WebHomeCoreError.code(.shapeChanged)
        }
        if string.localizedCaseInsensitiveContains("consent.youtube.com")
            || string.localizedCaseInsensitiveContains("recaptcha") {
            throw WebHomeCoreError.code(.consentOrCaptchaRequired)
        }
        guard let apiKey = capture("INNERTUBE_API_KEY", in: string),
              let clientVersion = capture("INNERTUBE_CLIENT_VERSION", in: string),
              let visitorData = capture("VISITOR_DATA", in: string),
              !apiKey.isEmpty,
              !clientVersion.isEmpty,
              !visitorData.isEmpty else {
            throw WebHomeCoreError.code(.shapeChanged)
        }
        return WebHomeBootstrapContext(
            apiKey: apiKey,
            clientVersion: clientVersion,
            visitorData: visitorData,
            locale: locale,
            region: region)
    }

    private func capture(_ key: String, in string: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let pattern = "[\\\"]\(escaped)[\\\"]\\s*:\\s*[\\\"]([^\\\"]+)[\\\"]"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: string, range: NSRange(string.startIndex..., in: string)),
              let range = Range(match.range(at: 1), in: string) else { return nil }
        return String(string[range])
    }
}

struct WebHomeIdentityParser: Sendable {
    func channelID(from data: Data) throws -> String {
        guard data.count <= 2 * 1024 * 1024,
              let root = try? JSONSerialization.jsonObject(with: data) else {
            throw WebHomeCoreError.code(.identityUnavailable)
        }
        guard let candidate = exactActiveChannelID(in: root),
              isChannelID(candidate) else {
            throw WebHomeCoreError.code(.identityUnavailable)
        }
        return candidate
    }

    private func exactActiveChannelID(in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            // The current account menu no longer places channelId inside
            // activeAccountHeaderRenderer. Its exact "your channel" endpoint
            // is a compact link in the same multi-page menu. Accept it only
            // when that menu has an active-account header and resolves to one
            // unique channel ID; never scan arbitrary browse endpoints.
            if let menu = dictionary["multiPageMenuRenderer"] as? [String: Any],
               hasActiveAccountHeader(in: menu),
               let channelID = uniqueCurrentChannelLinkID(in: menu) {
                return channelID
            }
            if let header = dictionary["activeAccountHeaderRenderer"] as? [String: Any],
               let channelID = explicitChannelID(in: header) {
                return channelID
            }
            if let item = dictionary["accountItemRenderer"] as? [String: Any],
               item["isSelected"] as? Bool == true,
               let channelID = explicitChannelID(in: item) {
                return channelID
            }
            for child in dictionary.values {
                if let found = exactActiveChannelID(in: child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = exactActiveChannelID(in: child) { return found }
            }
        }
        return nil
    }

    private func hasActiveAccountHeader(in menu: [String: Any]) -> Bool {
        guard let header = menu["header"] as? [String: Any],
              header["activeAccountHeaderRenderer"] is [String: Any] else {
            return false
        }
        return true
    }

    private func uniqueCurrentChannelLinkID(in menu: [String: Any]) -> String? {
        guard let sections = menu["sections"] as? [Any] else { return nil }
        var candidates = Set<String>()
        for sectionValue in sections {
            guard let section = sectionValue as? [String: Any],
                  let renderer = section["multiPageMenuSectionRenderer"]
                    as? [String: Any],
                  let items = renderer["items"] as? [Any] else { continue }
            for itemValue in items {
                guard let item = itemValue as? [String: Any],
                      let compactLink = item["compactLinkRenderer"]
                        as? [String: Any],
                      let endpoint = compactLink["navigationEndpoint"]
                        as? [String: Any],
                      let browse = endpoint["browseEndpoint"] as? [String: Any],
                      let browseID = browse["browseId"] as? String,
                      isChannelID(browseID) else { continue }
                candidates.insert(browseID)
            }
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    private func explicitChannelID(in dictionary: [String: Any]) -> String? {
        for key in ["channelId", "channelID", "browseId"] {
            if let value = dictionary[key] as? String, isChannelID(value) {
                return value
            }
        }
        if let endpoint = dictionary["browseEndpoint"] as? [String: Any],
           let browseID = endpoint["browseId"] as? String,
           isChannelID(browseID) {
            return browseID
        }
        for key in ["endpoint", "serviceEndpoint", "navigationEndpoint"] {
            if let child = dictionary[key] as? [String: Any],
               let value = explicitChannelID(in: child) {
                return value
            }
        }
        return nil
    }

    private func isChannelID(_ value: String) -> Bool {
        guard value.hasPrefix("UC"), value.count >= 20, value.count <= 32 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0.value == 45 || $0.value == 95
        }
    }
}

final class WebHomeSessionClient: @unchecked Sendable {
    /// YouTube Music serves a reduced, non-bootstrap HTML shell to generic
    /// URLSession clients. Use a fixed desktop Web identity so the one-shot
    /// helper receives the same configuration shape as a normal browser,
    /// without forwarding any device- or browser-specific identifier.
    static let desktopWebUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Chrome/140.0.0.0 Safari/537.36"

    private let transport: any WebHomeTransport
    private let bootstrapParser: WebHomeBootstrapParser
    private let identityParser: WebHomeIdentityParser
    private let now: @Sendable () -> Date

    init(
        transport: any WebHomeTransport = URLSessionWebHomeTransport(),
        bootstrapParser: WebHomeBootstrapParser = .init(),
        identityParser: WebHomeIdentityParser = .init(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.bootstrapParser = bootstrapParser
        self.identityParser = identityParser
        self.now = now
    }

    func execute(
        request: WebHomeRequest,
        cookies: WebHomeCookieJar
    ) async throws -> WebHomeSessionResult {
        let timeout = min(12, max(1, Double(request.timeoutMilliseconds) / 1_000))
        let bootstrapResponse = try await send(
            request: URLRequest(url: URL(string: "https://music.youtube.com/")!),
            timeout: timeout,
            cookies: cookies,
            context: nil,
            body: nil)
        guard bootstrapResponse.statusCode == 200 else {
            throw statusError(bootstrapResponse.statusCode)
        }
        if bootstrapResponse.finalURL?.host?.contains("consent.youtube.com") == true {
            throw WebHomeCoreError.code(.consentOrCaptchaRequired)
        }
        let context = try bootstrapParser.parse(
            html: bootstrapResponse.data,
            locale: request.locale,
            region: request.region)

        let identityResponse = try await post(
            endpoint: "account/account_menu",
            context: context,
            cookies: cookies,
            timeout: timeout,
            extraBody: [:])
        let channelID = try identityParser.channelID(from: identityResponse)
        guard channelID == request.expectedChannelID else {
            throw WebHomeCoreError.code(.accountMismatch)
        }

        guard request.action != .probeSession else {
            return WebHomeSessionResult(context: context, channelID: channelID, payload: nil)
        }
        let extraBody: [String: Any]
        switch request.action {
        case .fetchHome:
            extraBody = ["browseId": "FEmusic_home"]
        case .fetchContinuation:
            guard let handle = request.continuationHandle, !handle.isEmpty else {
                throw WebHomeCoreError.code(.malformedResponse)
            }
            extraBody = ["continuation": handle]
        case .probeSession:
            extraBody = [:]
        }
        let payload = try await post(
            endpoint: "browse",
            context: context,
            cookies: cookies,
            timeout: timeout,
            extraBody: extraBody)
        return WebHomeSessionResult(context: context, channelID: channelID, payload: payload)
    }

    private func post(
        endpoint: String,
        context: WebHomeBootstrapContext,
        cookies: WebHomeCookieJar,
        timeout: TimeInterval,
        extraBody: [String: Any]
    ) async throws -> Data {
        var components = URLComponents(
            string: "https://music.youtube.com/youtubei/v1/\(endpoint)")!
        components.queryItems = [
            URLQueryItem(name: "key", value: context.apiKey),
            URLQueryItem(name: "prettyPrint", value: "false")
        ]
        var body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB_REMIX",
                    "clientVersion": context.clientVersion,
                    "hl": context.locale,
                    "gl": context.region,
                    "visitorData": context.visitorData
                ],
                "user": ["enableSafetyMode": false]
            ]
        ]
        for (key, value) in extraBody { body[key] = value }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let response = try await send(
            request: URLRequest(url: components.url!),
            timeout: timeout,
            cookies: cookies,
            context: context,
            body: bodyData)
        guard response.statusCode == 200 else {
            throw statusError(response.statusCode)
        }
        guard response.data.count <= 10 * 1024 * 1024 else {
            throw WebHomeCoreError.code(.responseTooLarge)
        }
        return response.data
    }

    private func send(
        request base: URLRequest,
        timeout: TimeInterval,
        cookies: WebHomeCookieJar,
        context: WebHomeBootstrapContext?,
        body: Data?
    ) async throws -> WebHomeTransportResponse {
        guard let sapisid = cookies.sapisid else {
            throw WebHomeCoreError.code(.sessionExpired)
        }
        var request = base
        request.timeoutInterval = timeout
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(Self.desktopWebUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(cookies.header(for: "music.youtube.com"), forHTTPHeaderField: "Cookie")
        request.setValue(authorization(sapisid: sapisid), forHTTPHeaderField: "Authorization")
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let context {
            request.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
            request.setValue(context.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
            request.setValue(context.visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        do {
            return try await transport.data(for: request)
        } catch let error as WebHomeCoreError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw WebHomeCoreError.code(.timedOut)
            case .cancelled: throw WebHomeCoreError.code(.cancelled)
            default: throw WebHomeCoreError.code(.offline)
            }
        } catch is CancellationError {
            throw WebHomeCoreError.code(.cancelled)
        } catch {
            throw WebHomeCoreError.code(.offline)
        }
    }

    private func authorization(sapisid: String) -> String {
        let timestamp = Int(now().timeIntervalSince1970)
        let input = Data("\(timestamp) \(sapisid) https://music.youtube.com".utf8)
        let digest = Insecure.SHA1.hash(data: input)
            .map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(timestamp)_\(digest)"
    }

    private func statusError(_ status: Int) -> WebHomeCoreError {
        switch status {
        case 401, 403: .code(.sessionExpired)
        case 429: .code(.rateLimited)
        default: .code(.offline)
        }
    }
}
