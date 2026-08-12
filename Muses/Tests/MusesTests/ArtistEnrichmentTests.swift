import Testing
import Foundation
import SwiftData
@testable import Muses

@MainActor
@Suite("ArtistEnrichment")
struct ArtistEnrichmentTests {

    @Test("enrichArtist 写回 itunesArtistId/primaryGenre/artworkHash")
    func enrichArtistWritesFields() async throws {
        let container = try makeModelContainer(inMemory: true)
        let ctx = container.mainContext

        let artist = Artist(name: "Daft Punk")
        ctx.insert(artist)
        try ctx.save()
        let artistId = artist.id

        // Canned iTunes artist search JSON (entity=song&attribute=artistTerm).
        let itunesJSON = """
        {
          "results": [
            {
              "artistId": 5443,
              "artistName": "Daft Punk",
              "primaryGenreName": "Electronic",
              "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/abc/100x100bb.jpg"
            }
          ]
        }
        """
        // 2x2 red PNG — minimal valid image.
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

        StubURLProtocol.reset()
        let stub = StubURLProtocol()
        stub.respond(forHostEndingWith: "itunes.apple.com") { _ in
            StubResponse(statusCode: 200, body: Data(itunesJSON.utf8))
        }
        stub.respond(forHostContaining: "mzstatic.com") { _ in
            StubResponse(statusCode: 200, body: pngData)
        }

        let session = URLSession(configuration: StubURLProtocol.makeConfig(stub))
        let artworkCache = ArtworkCache(directory: FileManager.default.temporaryDirectory
            .appending(path: "muses-artist-enrich-\(UUID().uuidString)"))
        let enricher = MetadataEnricherService(
            session: session,
            artworkCache: artworkCache,
            modelContainer: container
        )

        let succeeded = await enricher.enrichArtist(artistId: artistId)
        #expect(succeeded == true)

        // Re-fetch in fresh context to verify persistence.
        let verifyCtx = ModelContext(container)
        let fetched = try #require(verifyCtx.fetch(FetchDescriptor<Artist>(
            predicate: #Predicate { $0.id == artistId })).first)

        #expect(fetched.itunesArtistId == 5443)
        #expect(fetched.primaryGenre == "Electronic")
        #expect(fetched.artworkHash != nil)
        #expect(fetched.artworkUrl?.contains("600x600bb") == true)
        if let hash = fetched.artworkHash {
            #expect(artworkCache.data(forHash: hash) != nil)
        }
    }

    @Test("enrichArtist 空结果返回 false")
    func enrichArtistNoResults() async throws {
        let container = try makeModelContainer(inMemory: true)
        let ctx = container.mainContext

        let artist = Artist(name: "Unknown")
        ctx.insert(artist)
        try ctx.save()
        let artistId = artist.id

        StubURLProtocol.reset()
        let stub = StubURLProtocol()
        stub.respond(forHostEndingWith: "itunes.apple.com") { _ in
            StubResponse(statusCode: 200, body: Data(#"{"results": []}"#.utf8))
        }

        let session = URLSession(configuration: StubURLProtocol.makeConfig(stub))
        let artworkCache = ArtworkCache(directory: FileManager.default.temporaryDirectory
            .appending(path: "muses-artist-empty-\(UUID().uuidString)"))
        let enricher = MetadataEnricherService(
            session: session, artworkCache: artworkCache, modelContainer: container)

        let succeeded = await enricher.enrichArtist(artistId: artistId)
        #expect(succeeded == false)

        let verifyCtx = ModelContext(container)
        let fetched = try #require(verifyCtx.fetch(FetchDescriptor<Artist>(
            predicate: #Predicate { $0.id == artistId })).first)
        #expect(fetched.artworkHash == nil)
        #expect(fetched.primaryGenre == nil)
    }

    @Test("EnrichmentEndpoint.itunesArtistSearch 构建正确 URL")
    func artistSearchURLEncoding() throws {
        let url = EnrichmentEndpoint.itunesArtistSearch(term: "Daft Punk")
        let s = url.absoluteString
        #expect(s.contains("itunes.apple.com/search"))
        #expect(s.contains("entity=song"))
        #expect(s.contains("attribute=artistTerm"))
        #expect(s.contains("limit=1"))
        #expect(!s.contains(" "))  // no raw spaces

        let mb = EnrichmentEndpoint.musicBrainzArtist(query: "Daft Punk")
        #expect(mb.absoluteString.contains("musicbrainz.org/ws/2/artist/"))
        #expect(mb.absoluteString.contains("fmt=json"))
    }
}