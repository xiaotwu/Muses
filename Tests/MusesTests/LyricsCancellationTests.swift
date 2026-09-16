import Foundation
import Testing
@testable import Muses

@MainActor
@Suite("Lyrics lookup cancellation", .serialized)
struct LyricsCancellationTests {
    @Test("manual choice wins over an already pending automatic lookup")
    func manualChoiceWins() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LyricsRaceProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); LyricsRaceProtocol.onRequest = nil }
        let service = LyricsService(session: session, documentCache: LyricsDocumentCache(directory: directory))
        let track = TrackSnapshot(id: UUID(), title: "Test Song", artist: "Test Artist", albumTitle: nil,
                                  durationSeconds: 180, youTubeId: "testvideo01", artworkUrl: nil,
                                  sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false)
        LyricsRaceProtocol.onRequest = {
            service.choose(LyricsCandidate(id: 2, trackName: "Test Song", artistName: "Test Artist", albumName: nil,
                                           duration: 180, instrumental: false, plainLyrics: "Manual choice", syncedLyrics: "[00:01]Manual choice"), for: track)
        }
        let result = await service.fetch(track: track)
        #expect(result?.plainLyrics == "Manual choice")
        #expect(service.fetchCached(track: track)?.plainLyrics == "Manual choice")
    }

    @Test("cancelled lookup cannot publish or cache its network result")
    func cancelledLookup() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LyricsRaceProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); LyricsRaceProtocol.onRequest = nil }
        let service = LyricsService(session: session)
        let track = TrackSnapshot(id: UUID(), title: "Test Song", artist: "Test Artist", albumTitle: nil,
                                  durationSeconds: 180, youTubeId: "testvideo02", artworkUrl: nil,
                                  sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false)
        var task: Task<LyricsResult?, Never>?
        LyricsRaceProtocol.onRequest = { task?.cancel() }
        task = Task { await service.fetch(track: track) }
        #expect(await task?.value == nil)
        #expect(service.fetchCached(track: track) == nil)
    }
}

private final class LyricsRaceProtocol: URLProtocol, @unchecked Sendable {
    @MainActor static var onRequest: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in
            Self.onRequest?()
            let data = Data(#"{"id":1,"trackName":"Test Song","artistName":"Test Artist","duration":180,"instrumental":false,"plainLyrics":"Automatic result","syncedLyrics":"[00:01]Automatic result"}"#.utf8)
            guard let url = request.url else { return }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
