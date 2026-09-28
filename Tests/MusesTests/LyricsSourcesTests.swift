import Foundation
import Testing
@testable import Muses

@MainActor
@Suite("Lyrics source expansion", .serialized)
struct LyricsSourcesTests {
    private func track(title: String = "Test Song (Official Video)", artist: String = "Test Artist - Topic") -> TrackSnapshot {
        .init(id: UUID(), title: title, artist: artist, albumTitle: nil, durationSeconds: 180,
              youTubeId: "testvideo01", artworkUrl: nil, sampleRate: nil, bitDepth: nil,
              codec: nil, isLossless: false)
    }

    @Test("OVH paths escape artist separators and Unicode without changing segments")
    func endpointEncoding() {
        let url = LyricsEndpoint.lyricsOVH(track: "歌 / Song?#", artist: "AC/DC")
        #expect(url.absoluteString.contains("AC%2FDC"))
        #expect(url.absoluteString.contains("%2F"))
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.query == nil)
        #expect(url.fragment == nil)
    }

    @Test("AI queries must quote supplied metadata and preserve recording versions")
    func groundedQueries() {
        let recording = track(title: "Test Artist - Test Song (Live) [Official Video]", artist: "Publisher")
        #expect(LyricsSearchQuery.validated(title: "Test Song (Live)", artist: "Test Artist", track: recording) != nil)
        #expect(LyricsSearchQuery.validated(title: "Test Song", artist: "Test Artist", track: recording) == nil)
        #expect(LyricsSearchQuery.validated(title: "Invented Song", artist: "Test Artist", track: recording) == nil)
        #expect(LyricsSearchQuery.validated(title: "Test Song (Live)", artist: "Invented Artist", track: recording) == nil)
        #expect(LyricsSearchQuery.validated(title: "!!!", artist: "Publisher", track: recording) == nil)
    }

    @Test("automatic fallback retains OVH provenance and never invents timing")
    func fallbackAndManualChoice() async throws {
        let suite = "MusesTests.lyricsSources.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: PrefKey.lyricsIntelligence)
        preferences.set("auto", forKey: PrefKey.lyricsSource)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LyricsSourcesProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let service = LyricsService(session: session, offsetDefaults: preferences)
        let recording = track()
        let result = await service.fetch(track: recording)
        #expect(result?.source == .lyricsOVH)
        #expect(result?.syncedLyrics == nil)
        #expect(result?.plainLyrics == "Synthetic test line")
        let candidates = await service.findCandidates(track: recording, source: "lyricsOVH")
        #expect(candidates.count == 1)
        #expect(candidates.first?.source == .lyricsOVH)
        service.choose(try #require(candidates.first), for: recording)
        #expect(service.fetchCached(track: recording)?.source == .lyricsOVH)
    }

    @Test("immersive lyrics center text without losing large playback styling")
    func centeredImmersiveLayout() {
        #expect(LyricsLayout.immersiveCentered.alignment == .center)
        #expect(LyricsLayout.immersiveCentered.textAlignment == .center)
        #expect(LyricsLayout.immersiveCentered.isImmersive)
    }
}

private final class LyricsSourcesProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let isOVH = request.url?.host == "api.lyrics.ovh"
        let response = HTTPURLResponse(url: request.url!, statusCode: isOVH ? 200 : 404,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((isOVH ? #"{"lyrics":"Synthetic test line"}"# : "{}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
