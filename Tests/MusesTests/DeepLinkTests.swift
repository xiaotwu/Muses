import Testing
import Foundation
import SwiftData
@testable import Muses

/// End-to-end deep link test: `muses://play?trackId=<id>` → parse → fetch the Track from the store
/// -> convert to a TrackSnapshot -> PlaybackService.playTrack routes it to the engine.
@MainActor
@Suite("DeepLink")
struct DeepLinkTests {

    /// Builds an in-memory container seeded with one local Track; returns (container, track).
    private func makeContainerWithTrack() throws -> (ModelContainer, Track) {
        let container = try makeModelContainer(inMemory: true)
        let context = container.mainContext
        let track = Track(title: "Deep", artist: "Linker",
                          durationMs: 180_000, youTubeId: "test-video")
        context.insert(track)
        try context.save()
        return (container, track)
    }

    @Test("muses://play?trackId parses and plays the matching track")
    func deepLinkParsesAndPlays() async throws {
        let (container, track) = try makeContainerWithTrack()
        let url = URL(string: "muses://play?trackId=\(track.id.uuidString)")!

        // 1. SpotlightIndexer parses the trackId.
        let parsedId = try #require(SpotlightIndexer.trackId(from: url))
        #expect(parsedId == track.id)

        // 2. The store fetches the Track by id (same logic as MusesApp.onOpenURL).
        let context = container.mainContext
        let descriptor = FetchDescriptor<Track>()
        let fetched = (try context.fetch(descriptor)).first { $0.id == parsedId }
        let resolved = try #require(fetched)
        #expect(resolved.title == "Deep")

        // 3. Convert to a snapshot and hand it to PlaybackService; verify the engine received the load.
        let engine = RecordingEngine()
        let svc = PlaybackService(youtubeEngine: engine, queue: QueueService())
        let snap = TrackSnapshot(from: resolved)
        svc.playTrack(snap, context: [snap], from: .songs)
        try await Task.sleep(for: .milliseconds(120))
        #expect(engine.loadCallCount == 1)
        #expect(engine.lastLoadedTrack?.title == "Deep")
    }

    @Test("非 muses scheme 或缺 trackId 返回 nil")
    func invalidDeepLinkReturnsNil() {
        #expect(SpotlightIndexer.trackId(from: URL(string: "https://example.com")!) == nil)
        #expect(SpotlightIndexer.trackId(from: URL(string: "muses://play")!) == nil)
        #expect(SpotlightIndexer.trackId(from: URL(string: "muses://play?trackId=not-a-uuid")!) == nil)
    }
}
