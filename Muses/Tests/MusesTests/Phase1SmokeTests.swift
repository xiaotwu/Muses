import Testing
import Foundation
@testable import Muses

@MainActor
@Suite("Phase 1 Smoke")
struct Phase1SmokeTests {
    @Test("full flow: scan → list albums → play → advance")
    func fullFlow() async throws {
        let cacheDir = FileManager.default.temporaryDirectory.appending(path: "muses-smoke-\(UUID().uuidString)")
        let container = try makeModelContainer(inMemory: true)
        let meta = MetadataService(artworkCache: ArtworkCache(directory: cacheDir))
        let library = LibraryService(modelContainer: container, metadata: meta)
        let dir = FileManager.default.temporaryDirectory.appending(path: "muses-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in 0..<2 {
            try makeSilentWav(at: dir.appending(path: "tone\(n).wav"), seconds: 1)
        }

        try await library.addScanRoot(dir, watch: false)
        #expect(library.allAlbums().count >= 1)
        let tracks = library.allTracks()
        #expect(tracks.count == 2)

        let engine = LocalAudioEngine()
        let queue = QueueService()
        let pb = PlaybackService(engine: engine, queue: queue)

        let ctx = tracks.map { TrackSnapshot(from: $0) }
        pb.playTrack(ctx[0], context: ctx, from: .album)
        try await Task.sleep(for: .milliseconds(150))
        #expect(pb.state.track?.title == ctx[0].title)

        pb.next()
        try await Task.sleep(for: .milliseconds(150))
        #expect(pb.state.track?.title == ctx[1].title)
    }
}