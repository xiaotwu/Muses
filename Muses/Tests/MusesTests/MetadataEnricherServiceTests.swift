import Testing
import Foundation
import SwiftData
@testable import Muses

@MainActor
@Suite("MetadataEnricherService", .serialized)
struct MetadataEnricherServiceTests {

    // MARK: - iTunes search upgrades artwork and backfills metadata

    @Test("iTunes search upgrades artwork URL and backfills metadata")
    func itunesSearchUpgradesArtwork() async throws {
        let container = try makeModelContainer(inMemory: true)
        let ctx = container.mainContext

        // Track has only embedded metadata — no artwork, no album.
        let track = Track(
            source: .local,
            title: "One More Time",
            artist: "Daft Punk",
            albumTitle: nil,
            durationMs: 320_000,
            filePath: "/tmp/one-more-time.wav",
            metadataStatus: .embedded
        )
        ctx.insert(track)
        try ctx.save()
        let trackId = track.id

        // Canned iTunes JSON: artworkUrl100 contains "100x100bb" — the enricher
        // should upgrade it to "600x600bb".
        let itunesJSON = """
        {
          "results": [
            {
              "trackName": "One More Time",
              "artistName": "Daft Punk",
              "collectionName": "Discovery",
              "releaseDate": "2001-03-07T08:00:00Z",
              "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/abc/100x100bb.jpg"
            }
          ]
        }
        """
        // 2x2 red PNG — minimal valid image so ArtworkCache.store succeeds.
        let pngBytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
            0x08, 0x02, 0x00, 0x00, 0x00, 0xFD, 0x5E, 0x60,
            0x7A, 0x00, 0x00, 0x00, 0x1A, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x62, 0xFE, 0x3F, 0x0F, 0x70,
            0x00, 0x00, 0x00, 0x06, 0x00, 0x05, 0xFE, 0x2D,
            0x8C, 0x10, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
            0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
        ]
        let pngData = Data(pngBytes)

        MetadataEnrichStub.reset()
        let stub = MetadataEnrichStub()
        stub.respond(forHostEndingWith: "itunes.apple.com") { _ in
            StubResponse(statusCode: 200, body: Data(itunesJSON.utf8))
        }
        stub.respond(forHostContaining: "mzstatic.com") { _ in
            StubResponse(statusCode: 200, body: pngData)
        }
        // MusicBrainz should NOT be hit for this test — register a 404 so a
        // regression would surface as `.missing` rather than silently passing.
        stub.respond(forHostContaining: "musicbrainz.org") { _ in
            StubResponse(statusCode: 404, body: Data())
        }
        stub.respond(forHostContaining: "coverartarchive.org") { _ in
            StubResponse(statusCode: 404, body: Data())
        }

        let session = URLSession(configuration: MetadataEnrichStub.makeConfig())
        let artworkCache = ArtworkCache(directory: FileManager.default.temporaryDirectory
            .appending(path: "muses-enrich-test-\(UUID().uuidString)"))
        let enricher = MetadataEnricherService(
            session: session,
            artworkCache: artworkCache,
            modelContainer: container
        )

        let succeeded = await enricher.enrich(trackId: trackId)
        #expect(succeeded == true)

        // Re-fetch in a fresh context to verify persistence.
        let verifyCtx = ModelContext(container)
        let fetched = try #require(verifyCtx.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.id == trackId })).first)

        #expect(fetched.metadataStatus == .complete)
        // Artwork URL upgraded from 100x100bb to 600x600bb.
        #expect(fetched.artworkUrl?.contains("600x600bb") == true)
        #expect(fetched.artworkUrl?.contains("100x100bb") == false)
        // Album title backfilled from collectionName.
        #expect(fetched.albumTitle == "Discovery")
        // Year parsed from releaseDate.
        #expect(fetched.year == 2001)
        // Artwork data was downloaded and stored locally.
        #expect(fetched.localArtworkHash != nil)
        if let hash = fetched.localArtworkHash {
            #expect(artworkCache.data(forHash: hash) != nil)
        }
    }

    // MARK: - No results sets metadataStatus to missing

    @Test("no results sets metadataStatus to missing")
    func noResultsSetsMissing() async throws {
        let container = try makeModelContainer(inMemory: true)
        let ctx = container.mainContext

        let track = Track(
            source: .local,
            title: "Obscure Song",
            artist: "Unknown Artist",
            albumTitle: nil,
            durationMs: 180_000,
            filePath: "/tmp/obscure.wav",
            metadataStatus: .embedded
        )
        ctx.insert(track)
        try ctx.save()
        let trackId = track.id

        // Empty iTunes results.
        let itunesJSON = #"{"results": []}"#

        MetadataEnrichStub.reset()
        let stub = MetadataEnrichStub()
        stub.respond(forHostContaining: "itunes.apple.com") { _ in
            StubResponse(statusCode: 200, body: Data(itunesJSON.utf8))
        }
        // MusicBrainz returns empty release-groups.
        let mbJSON = #"{"release-groups": []}"#
        stub.respond(forHostContaining: "musicbrainz.org") { _ in
            StubResponse(statusCode: 200, body: Data(mbJSON.utf8))
        }

        let session = URLSession(configuration: MetadataEnrichStub.makeConfig())
        let artworkCache = ArtworkCache(directory: FileManager.default.temporaryDirectory
            .appending(path: "muses-enrich-missing-\(UUID().uuidString)"))
        let enricher = MetadataEnricherService(
            session: session,
            artworkCache: artworkCache,
            modelContainer: container
        )

        let succeeded = await enricher.enrich(trackId: trackId)
        #expect(succeeded == false)

        let verifyCtx = ModelContext(container)
        let fetched = try #require(verifyCtx.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.id == trackId })).first)
        #expect(fetched.metadataStatus == .missing)
        #expect(fetched.artworkUrl == nil)
        #expect(fetched.albumTitle == nil)
    }

    // MARK: - EnrichmentEndpoint URL builders

    @Test("EnrichmentEndpoint builds percent-encoded URLs")
    func endpointURLEncoding() throws {
        let itunes = EnrichmentEndpoint.itunesSearch(term: "Daft Punk One More Time")
        #expect(itunes.absoluteString.contains("itunes.apple.com/search"))
        #expect(itunes.absoluteString.contains("entity=song"))
        #expect(itunes.absoluteString.contains("limit=5"))
        // Spaces encoded (either as %20 or +).
        let encoded = itunes.absoluteString
        #expect(!encoded.contains(" "))  // no raw spaces

        let mb = EnrichmentEndpoint.musicBrainzReleaseGroup(query: "Discovery")
        #expect(mb.absoluteString.contains("musicbrainz.org/ws/2/release-group/"))
        #expect(mb.absoluteString.contains("fmt=json"))

        let cover = EnrichmentEndpoint.coverArt(releaseId: "abc-123")
        #expect(cover.absoluteString == "https://coverartarchive.org/release/abc-123/front")
    }

    @Test("EnrichmentEndpoint.upgradeItunesArtwork replaces 100x100bb with 600x600bb")
    func upgradeArtworkToken() {
        let upgraded = EnrichmentEndpoint.upgradeItunesArtwork(
            "https://is1-ssl.mzstatic.com/image/thumb/abc/100x100bb.jpg")
        #expect(upgraded == "https://is1-ssl.mzstatic.com/image/thumb/abc/600x600bb.jpg")
        // No token present -> returned unchanged.
        let noToken = "https://example.com/image.jpg"
        #expect(EnrichmentEndpoint.upgradeItunesArtwork(noToken) == noToken)
    }
}

// MARK: - Per-suite URLProtocol stub (isolated rule store for this suite)

final class MetadataEnrichStub: StubURLProtocolBase, @unchecked Sendable {
    nonisolated(unsafe) private static var _rules: [StubRule] = []
    private static let _lock = NSLock()
    override class var rules: [StubRule] {
        get { _rules } set { _rules = newValue }
    }
    override class var lock: NSLock { _lock }
}