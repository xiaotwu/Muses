import Foundation
import Testing
@testable import Muses

@Suite("Innertube Home")
struct InnertubeHomeTests {
    @Test("anonymous parser normalizes supported renderers and ignores raw fields")
    func parserNormalizesFixture() throws {
        let page = try InnertubeHomeParser().parse(fixture("supported-home"))

        #expect(page.parserSchemaVersion == 1)
        #expect(page.sections.count == 4)
        #expect(Set(page.sections.map(\.kind))
                == Set([.youTubeCarousel, .songGrid, .mixed, .quickPicks]))
        #expect(page.sections.allSatisfy { $0.id.hasPrefix("ytm:FEmusic_home:") })
        #expect(page.sections.allSatisfy { $0.source == .publicDiscovery })
        #expect(page.sections.flatMap(\.items).allSatisfy { $0.homeMediaIdentity != nil })
        #expect(page.shelfContinuations.values.contains("VOLATILE_CAROUSEL_TOKEN"))
        #expect(page.continuation == nil)
    }

    @Test("two-row playlist artwork keeps trusted images and safe missing fallbacks")
    func twoRowArtwork() throws {
        let page = try InnertubeHomeParser().parse(fixture("two-row-artwork"))
        let cards = page.sections.flatMap(\.items).compactMap { item -> YouTubeDiscoveryCard? in
            guard case .youTube(let card) = item else { return nil }
            return card
        }
        #expect(cards.count == 3)
        #expect(cards[0].thumbnailURL == "https://yt3.googleusercontent.com/cover=w544-h544")
        #expect(cards[1].thumbnailURL == nil)
        #expect(cards[2].thumbnailURL == nil)
    }

    @Test("unknown-only response fails closed")
    func unknownOnlyFailsClosed() throws {
        #expect(throws: InnertubeError.shapeChanged) {
            try InnertubeHomeParser().parse(fixture("unknown-only"))
        }
    }

    @Test("anonymous client sends no cookies, auth, or local recommendation signals")
    func anonymousRequestPrivacyBoundary() async throws {
        let bootstrap = Data("""
        <script>window.ytcfg={"INNERTUBE_API_KEY":"public-key",
        "INNERTUBE_CLIENT_VERSION":"1.20260917.00.00",
        "VISITOR_DATA":"guest-visitor"};</script>
        """.utf8)
        let transport = RecordingInnertubeTransport(responses: [
            .init(data: bootstrap, statusCode: 200),
            .init(data: try fixture("supported-home"), statusCode: 200)
        ])
        let configuration = InnertubeClientConfiguration(
            clientName: "WEB_REMIX", clientVersion: nil,
            language: "en", region: "US", userAgent: "MusesTests",
            requestTimeout: 1, maximumResponseBytes: 5 * 1024 * 1024)
        let client = InnertubeClient(configuration: configuration, transport: transport)

        _ = try await client.home(continuation: nil)
        let requests = await transport.recorded()
        let browse = try #require(requests.last)

        #expect(requests.count == 2)
        #expect(browse.headers["Cookie"] == nil)
        #expect(browse.headers["Authorization"] == nil)
        #expect(browse.body?.contains("FEmusic_home") == true)
        #expect(browse.body?.contains("likedArtistNames") == false)
        #expect(browse.body?.contains("seedVideo") == false)
    }

    @Test("mode cache trees cannot read each other's snapshot")
    @MainActor
    func cacheModeIsolation() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muses-home-mode-\(UUID().uuidString)", isDirectory: true)
        let cache = HomeFeedCache(directory: root)
        let input = HomeDiscoveryInput(
            topArtistNames: [], recentlyPlayedArtistNames: [], likedArtistNames: [],
            timeBand: .morning, hour: 9, scope: .guest)
        let now = Date()
        let snapshot = HomeSnapshot(
            scope: .guest,
            sections: [HomeSection(
                id: "muses-only", title: "Muses", kind: .youTubeCarousel,
                items: [], source: .localLibrary)],
            fetchedAt: now,
            expiresAt: now.addingTimeInterval(600))

        #expect(cache.set(snapshot, for: input, layer: .baseline, mode: .muses))
        #expect(cache.get(for: input, layer: .baseline, mode: .muses) != nil)
        #expect(cache.get(for: input, layer: .baseline, mode: .youtubeMusic) == nil)
        #expect(cache.directoryURL(for: .guest, layer: .baseline, mode: .muses).path
            .contains("/muses-v1/guest/"))
        #expect(cache.directoryURL(for: .guest, layer: .baseline, mode: .youtubeMusic).path
            .contains("/youtube-music-v1/guest/"))
    }

    @Test("Home cache and continuation identity include language and region")
    @MainActor
    func cacheLocaleIsolation() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muses-home-locale-\(UUID().uuidString)",
                                    isDirectory: true)
        let cache = HomeFeedCache(directory: root)
        let english = HomeDiscoveryInput(
            topArtistNames: [], recentlyPlayedArtistNames: [],
            likedArtistNames: [], timeBand: .morning, hour: 9,
            scope: .guest, language: "en", region: "US")
        let traditional = HomeDiscoveryInput(
            topArtistNames: [], recentlyPlayedArtistNames: [],
            likedArtistNames: [], timeBand: .morning, hour: 9,
            scope: .guest, language: "zh-Hant", region: "TW")
        let now = Date()
        let snapshot = HomeSnapshot(
            scope: .guest,
            sections: [HomeSection(
                id: "source", title: "Source", kind: .youTubeCarousel,
                items: [], source: .publicDiscovery)],
            fetchedAt: now, expiresAt: now.addingTimeInterval(600))

        #expect(cache.set(snapshot, for: english, layer: .baseline,
                          mode: .youtubeMusic))
        #expect(cache.get(for: english, layer: .baseline,
                          mode: .youtubeMusic) != nil)
        #expect(cache.get(for: traditional, layer: .baseline,
                          mode: .youtubeMusic) == nil)
        #expect(cache.directoryURL(
            for: .guest, layer: .baseline, mode: .youtubeMusic,
            language: "en", region: "US").path
            != cache.directoryURL(
                for: .guest, layer: .baseline, mode: .youtubeMusic,
                language: "zh-Hant", region: "TW").path)

        #expect(cache.set(snapshot, for: traditional, layer: .baseline,
                          mode: .youtubeMusic))
        let legacyLayer = root
            .appendingPathComponent(
                "youtube-music-v1/guest/\(HomeFeedCache.Layer.baseline.directoryName)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(
            at: legacyLayer, withIntermediateDirectories: true)
        let legacyFile = legacyLayer.appendingPathComponent("legacy.json")
        try? Data("legacy".utf8).write(to: legacyFile)
        cache.invalidate(scope: .guest, layer: .baseline,
                         mode: .youtubeMusic)
        #expect(cache.get(for: english, layer: .baseline,
                          mode: .youtubeMusic) == nil)
        #expect(cache.get(for: traditional, layer: .baseline,
                          mode: .youtubeMusic) == nil)
        #expect(!FileManager.default.fileExists(atPath: legacyFile.path))
    }

    @Test("local ranking is deterministic and contains only supplied tracks")
    func localRankingIsDeterministic() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let favorite = recommendationTrack(
            videoID: "favorite001", artist: "Artist", playCount: 8,
            favorite: true, lastPlayedAt: now.addingTimeInterval(-45 * 86_400))
        let recent = recommendationTrack(
            videoID: "recent00001", artist: "Artist", playCount: 3,
            favorite: false, lastPlayedAt: now.addingTimeInterval(-2 * 86_400))
        let input = LocalRecommendationInput(
            tracks: [recent, favorite], currentHour: 9, timeBand: .morning, now: now)
        let engine = LocalRecommendationEngine()

        let first = engine.plan(for: input)
        let second = engine.plan(for: input)

        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.flatMap(\.items).map(\.homeMediaIdentity)
            == second.flatMap(\.items).map(\.homeMediaIdentity))
        #expect(Set(first.flatMap(\.items).compactMap(\.homeMediaIdentity))
            .isSubset(of: ["video:favorite001", "video:recent00001"]))
        #expect(first.allSatisfy { $0.source == .localLibrary })
    }

    @Test("local recommendations never merge same-name artists without the same stable ID")
    func sameNameArtistsStaySeparate() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = recommendationTrack(videoID: "same-name-1", artist: "Atlas", playCount: 12,
                                        favorite: true, lastPlayedAt: now, artistCatalogID: "channel:first")
        let second = recommendationTrack(videoID: "same-name-2", artist: "Atlas", playCount: 11,
                                         favorite: true, lastPlayedAt: now, artistCatalogID: "channel:second")
        let sections = LocalRecommendationEngine().plan(for: .init(
            tracks: [first, second], currentHour: 9, timeBand: .morning, now: now))

        let artistSections = sections.filter { $0.id.hasPrefix("muses:artist:") }
        #expect(artistSections.count == 1)
        #expect(artistSections.first?.items.count == 1)
    }

    @Test("Real anonymous Home locale and shelf continuation matrix",
          .enabled(if: ProcessInfo.processInfo.environment[
            "MUSES_TEST_PUBLIC_CATALOG"] == "1"))
    @MainActor
    func liveAnonymousHomeMatrix() async throws {
        for (language, region) in [("en", "US"), ("zh-Hans", "US"), ("zh-Hant", "TW")] {
            let provider = AnonymousInnertubeHomeProvider { language, region in
                InnertubeClient(configuration: .current(
                    language: language, region: region))
            }
            let input = HomeDiscoveryInput(
                topArtistNames: [], recentlyPlayedArtistNames: [],
                likedArtistNames: [], timeBand: .morning, hour: 9,
                scope: .guest, language: language, region: region)
            let result = await provider.fetch(for: input)
            let sections = result.baselineSnapshot.sections
            #expect(result.failures.isEmpty, "Home locale: \(language)/\(region)")
            #expect(!sections.isEmpty, "Home locale: \(language)/\(region)")
            #expect(sections.allSatisfy { $0.source == .publicDiscovery })
            let playlistCards = sections.flatMap(\.items).compactMap { item -> YouTubeDiscoveryCard? in
                guard case .youTube(let card) = item,
                      card.browseEndpoint?.identifier.hasPrefix("VL") == true else { return nil }
                return card
            }
            #expect(!playlistCards.isEmpty)
            #expect(playlistCards.contains { $0.thumbnailURL != nil })

            if let section = sections.first(where: {
                provider.hasContinuation(for: $0.id)
            }) {
                let more = await provider.more(
                    sectionID: section.id, input: input)
                #expect(!more.isEmpty)
            }
        }
    }

    @Test("Real anonymous Home global continuation when supplied by service",
          .enabled(if: ProcessInfo.processInfo.environment[
            "MUSES_TEST_GLOBAL_HOME_CONTINUATION"] == "1"))
    func liveGlobalHomeContinuation() async throws {
        var continuedPage: InnertubeHomePage?
        for (language, region) in [
            ("en", "US"), ("en", "GB"), ("ja", "JP"),
            ("ko", "KR"), ("zh-Hant", "TW")
        ] {
            let client = InnertubeClient(configuration: .current(
                language: language, region: region))
            let first = try await client.home(continuation: nil)
            if let token = first.continuation {
                continuedPage = try await client.home(continuation: token)
                break
            }
        }
        let page = try #require(continuedPage)
        #expect(!page.sections.isEmpty)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/WebHome"))
        return try Data(contentsOf: url)
    }

    private func recommendationTrack(
        videoID: String,
        artist: String,
        playCount: Int,
        favorite: Bool,
        lastPlayedAt: Date?,
        artistCatalogID: String? = nil
    ) -> TrackRecommendationSnapshot {
        TrackRecommendationSnapshot(
            track: TrackSnapshot(
                id: UUID(), title: videoID, artist: artist, albumTitle: nil,
                durationSeconds: 180, youTubeId: videoID, artworkUrl: nil,
                sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false,
                liked: favorite),
            artistCatalogID: artistCatalogID ?? "channel:\(artist.lowercased())",
            playCount: playCount,
            isFavorite: favorite,
            addedAt: Date(timeIntervalSince1970: 1_900_000_000),
            lastPlayedAt: lastPlayedAt)
    }
}

private struct RecordedInnertubeRequest: Sendable {
    let headers: [String: String]
    let body: String?
}

private actor RecordingInnertubeTransport: InnertubeTransport {
    private var responses: [InnertubeTransportResponse]
    private var requests: [RecordedInnertubeRequest] = []

    init(responses: [InnertubeTransportResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> InnertubeTransportResponse {
        requests.append(RecordedInnertubeRequest(
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody.map { String(decoding: $0, as: UTF8.self) }))
        guard !responses.isEmpty else { throw InnertubeError.offline }
        return responses.removeFirst()
    }

    func recorded() -> [RecordedInnertubeRequest] { requests }
}
