import Foundation

/// Anonymous, read-only public catalog. Never shares OAuth, cookies, caches or
/// Web Home IPC. All continuations disappear when this session is reset.
actor PublicMusicCatalogProvider: MusicCatalogProviding {
    typealias Transport = @Sendable (URLRequest) async throws -> Data
    private static let origin = "https://music.youtube.com"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
    private let transport: Transport
    private let region: String
    private var generation = UUID()
    private var version: String?
    private var filters: [String: [MusicCatalogFilter]] = [:]

    init(region: String = "US", transport: Transport? = nil) {
        self.region = region
        if let transport { self.transport = transport }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 25
            configuration.timeoutIntervalForResource = 40
            let session = URLSession(configuration: configuration)
            self.transport = { request in
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      http.url?.scheme == "https", http.url?.host == "music.youtube.com" else {
                    throw MusicCatalogError.unavailable
                }
                guard data.count <= 8 * 1_024 * 1_024 else { throw MusicCatalogError.responseTooLarge }
                return data
            }
        }
    }

    func reset() {
        generation = UUID()
        version = nil
        filters.removeAll()
    }

    func search(_ query: String, kind: MusicCatalogKind? = nil) async throws -> MusicCatalogPage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 1_000 else { throw MusicCatalogError.invalidIdentity }
        let expected = generation
        var body: [String: String] = ["query": query]
        if let kind {
            if filters[query] == nil {
                let overview = try await request("search", body: body, expected: expected)
                filters[query] = overview.filters
            }
            guard let filter = filters[query]?.first(where: { $0.kind == kind }) else {
                throw MusicCatalogError.unsupportedCategory
            }
            body["params"] = filter.params
        }
        let page = try await request("search", body: body, expected: expected)
        if kind == nil {
            // Bounded volatile query state, never a persisted search history.
            if filters.count >= 20 { filters.removeAll() }
            filters[query] = page.filters
        }
        return page
    }

    func browse(_ id: String) async throws -> MusicCatalogPage {
        guard id.hasPrefix("browse:") else { throw MusicCatalogError.invalidIdentity }
        let sourceID = String(id.dropFirst(7))
        guard MusicCatalogParser.validID(sourceID) else { throw MusicCatalogError.invalidIdentity }
        return try await request("browse", body: ["browseId": sourceID], expected: generation)
    }

    /// Public Mix candidates; never uses keyword search or Web Home credentials.
    func recommendations(after videoID: String) async throws -> [MusicCatalogItem] {
        guard videoID.count == 11, MusicCatalogParser.validID(videoID) else { throw MusicCatalogError.invalidIdentity }
        let page = try await request("next", body: ["videoId": videoID, "playlistId": "RDAMVM" + videoID], expected: generation)
        return page.items.filter { $0.kind == .song && $0.id != "video:" + videoID }
    }

    func next(_ cursor: MusicCatalogCursor) async throws -> MusicCatalogPage {
        guard cursor.session == generation, ["search", "browse"].contains(cursor.endpoint) else {
            throw MusicCatalogError.expiredCursor
        }
        return try await request(cursor.endpoint, body: ["continuation": cursor.token], expected: cursor.session)
    }

    private func request(_ endpoint: String, body: [String: String], expected: UUID) async throws -> MusicCatalogPage {
        try Task.checkCancellation()
        let clientVersion = try await bootstrap(expected: expected)
        guard generation == expected else { throw MusicCatalogError.expiredCursor }
        var request = URLRequest(url: URL(string: Self.origin + "/youtubei/v1/" + endpoint + "?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = body
        payload["context"] = ["client": ["clientName": "WEB_REMIX", "clientVersion": clientVersion, "hl": "en", "gl": region]]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let data = try await transport(request)
        try Task.checkCancellation()
        guard expected == generation else { throw MusicCatalogError.expiredCursor }
        guard data.count <= 8 * 1_024 * 1_024 else { throw MusicCatalogError.responseTooLarge }
        return try MusicCatalogParser.page(data, session: expected, endpoint: endpoint, region: region)
    }

    private func bootstrap(expected: UUID) async throws -> String {
        if let version { return version }
        var request = URLRequest(url: URL(string: Self.origin + "/")!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let data = try await transport(request)
        try Task.checkCancellation()
        guard expected == generation else { throw MusicCatalogError.expiredCursor }
        guard data.count <= 8 * 1_024 * 1_024,
              let html = String(data: data, encoding: .utf8) else { throw MusicCatalogError.invalidResponse }
        // Obtain only the public client version. Visitor IDs and other page
        // configuration are neither retained nor transmitted.
        let regex = try NSRegularExpression(pattern: #""INNERTUBE_CLIENT_VERSION"\s*:\s*"([0-9.]+)""#)
        guard let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { throw MusicCatalogError.invalidResponse }
        let value = String(html[range])
        version = value
        return value
    }
}
