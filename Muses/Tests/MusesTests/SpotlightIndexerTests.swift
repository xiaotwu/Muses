import Testing
import Foundation
import SwiftData
@testable import Muses

@MainActor
@Suite("SpotlightIndexer")
struct SpotlightIndexerTests {
    @Test("deep link URL parses trackId")
    func deepLinkParse() {
        let id = UUID()
        let url = URL(string: "muses://play?trackId=\(id.uuidString)")!
        let parsed = SpotlightIndexer.trackId(from: url)
        #expect(parsed == id)
    }

    @Test("invalid URL returns nil")
    func invalidUrl() {
        #expect(SpotlightIndexer.trackId(from: URL(string: "https://example.com")!) == nil)
        #expect(SpotlightIndexer.trackId(from: URL(string: "muses://play?trackId=notauuid")!) == nil)
        #expect(SpotlightIndexer.trackId(from: URL(string: "muses://play")!) == nil)
    }

    @Test("indexAll does not crash with empty library")
    func indexAllEmpty() {
        let container = try! makeModelContainer(inMemory: true)
        let indexer = SpotlightIndexer(modelContainer: container)
        indexer.indexAll()
        indexer.deindexAll()
    }

    @Test("index with tracks does not crash")
    func indexWithTracks() {
        let container = try! makeModelContainer(inMemory: true)
        let ctx = ModelContext(container)
        let track = Track(title: "Test", artist: "Artist", youTubeId: "test-video")
        ctx.insert(track)
        try? ctx.save()

        let indexer = SpotlightIndexer(modelContainer: container)
        indexer.index(tracks: [track])
        indexer.deindex(ids: [track.id])
    }
}
