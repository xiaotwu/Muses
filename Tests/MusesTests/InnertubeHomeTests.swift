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
