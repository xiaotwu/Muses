import CryptoKit
import Foundation

struct InnertubeTransportResponse: Sendable {
    let data: Data
    let statusCode: Int
}

protocol InnertubeTransport: Sendable {
    func data(for request: URLRequest) async throws -> InnertubeTransportResponse
}

final class URLSessionInnertubeTransport: InnertubeTransport, @unchecked Sendable {
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

    func data(for request: URLRequest) async throws -> InnertubeTransportResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw InnertubeError.malformedResponse
        }
        return InnertubeTransportResponse(data: data, statusCode: http.statusCode)
    }
}

actor InnertubeClient: InnertubeServing {
    private struct Bootstrap: Sendable {
        let apiKey: String
        let clientVersion: String
        let visitorData: String?
    }

    private let configuration: InnertubeClientConfiguration
    private let transport: any InnertubeTransport
    private let parser: InnertubeHomeParser
    private var bootstrap: Bootstrap?
    private var inFlight: [String: Task<InnertubeHomePage, Error>] = [:]

    init(
        configuration: InnertubeClientConfiguration = .current,
        transport: any InnertubeTransport = URLSessionInnertubeTransport(),
        parser: InnertubeHomeParser = .init()
    ) {
        self.configuration = configuration
        self.transport = transport
        self.parser = parser
    }

    func home(continuation: String? = nil) async throws -> InnertubeHomePage {
        let identity = continuation.map(Self.tokenIdentity) ?? "home"
        if let task = inFlight[identity] { return try await task.value }
        let task = Task { try await self.performHome(continuation: continuation) }
        inFlight[identity] = task
        defer { inFlight.removeValue(forKey: identity) }
        return try await task.value
    }

    private func performHome(continuation: String?, retryBootstrap: Bool = true) async throws -> InnertubeHomePage {
        try Task.checkCancellation()
        let context = try await bootstrapContext()
        var components = URLComponents(string: "https://music.youtube.com/youtubei/v1/browse")!
        components.queryItems = [
            URLQueryItem(name: "key", value: context.apiKey),
            URLQueryItem(name: "prettyPrint", value: "false")
        ]
        var client: [String: Any] = [
            "clientName": configuration.clientName,
            "clientVersion": configuration.clientVersion ?? context.clientVersion,
            "hl": configuration.language,
            "gl": configuration.region
        ]
        if let visitorData = context.visitorData { client["visitorData"] = visitorData }
        var body: [String: Any] = ["context": ["client": client]]
        if let continuation {
            body["continuation"] = continuation
        } else {
            body["browseId"] = "FEmusic_home"
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.requestTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(configuration.clientVersion ?? context.clientVersion,
                         forHTTPHeaderField: "X-YouTube-Client-Version")
        if let visitorData = context.visitorData {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }

        await MainActor.run { PerfTrace.event("home.innertube.start") }
        do {
            let response = try await transport.data(for: request)
            try validate(response)
            let parsed = try parser.parse(response.data)
            await MainActor.run { PerfTrace.event("home.innertube.success") }
            return parsed
        } catch let error as InnertubeError {
            if error == .shapeChanged, retryBootstrap, continuation == nil {
                // YouTube can rotate the anonymous client bootstrap while the
                // process is alive. Retry once with a fresh public bootstrap;
                // never retain the old token or response.
                bootstrap = nil
                return try await performHome(continuation: nil, retryBootstrap: false)
            }
            await MainActor.run { PerfTrace.event("home.innertube.failure") }
            throw error
        } catch let error as URLError {
            await MainActor.run { PerfTrace.event("home.innertube.failure") }
            switch error.code {
            case .timedOut: throw InnertubeError.timedOut
            case .cancelled: throw InnertubeError.cancelled
            default: throw InnertubeError.offline
            }
        } catch is CancellationError {
            throw InnertubeError.cancelled
        } catch {
            await MainActor.run { PerfTrace.event("home.innertube.failure") }
            throw InnertubeError.offline
        }
    }

    private func bootstrapContext() async throws -> Bootstrap {
        if let bootstrap { return bootstrap }
        var request = URLRequest(url: URL(string: "https://music.youtube.com/")!)
        request.timeoutInterval = configuration.requestTimeout
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        let response: InnertubeTransportResponse
        do {
            response = try await transport.data(for: request)
        } catch let error as URLError {
            if error.code == .timedOut { throw InnertubeError.timedOut }
            if error.code == .cancelled { throw InnertubeError.cancelled }
            throw InnertubeError.offline
        }
        try validate(response)
        guard let html = String(data: response.data, encoding: .utf8),
              let apiKey = capture("INNERTUBE_API_KEY", in: html),
              let version = configuration.clientVersion
                ?? capture("INNERTUBE_CLIENT_VERSION", in: html) else {
            throw InnertubeError.shapeChanged
        }
        let value = Bootstrap(
            apiKey: apiKey,
            clientVersion: version,
            visitorData: capture("VISITOR_DATA", in: html))
        bootstrap = value
        return value
    }

    private func validate(_ response: InnertubeTransportResponse) throws {
        guard response.data.count <= configuration.maximumResponseBytes else {
            throw InnertubeError.responseTooLarge
        }
        switch response.statusCode {
        case 200..<300: return
        case 401, 403: throw InnertubeError.unauthorized
        case 429: throw InnertubeError.rateLimited
        default: throw InnertubeError.offline
        }
    }

    private func capture(_ key: String, in text: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        guard let regex = try? NSRegularExpression(
            pattern: "[\\\"]\(escaped)[\\\"]\\s*:\\s*[\\\"]([^\\\"]+)[\\\"]"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func tokenIdentity(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(12)
            .map { String(format: "%02x", $0) }.joined()
    }
}
