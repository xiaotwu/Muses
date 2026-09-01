import Testing
import Foundation
import SwiftData
@testable import Muses

@MainActor
@Suite("QueueServicePersistence")
struct QueueServicePersistenceTests {
    private func snap(_ t: String) -> TrackSnapshot {
        TrackSnapshot(id: UUID(), title: t, artist: "a", albumTitle: nil,
                      durationSeconds: 1, youTubeId: "test-video",
                      artworkUrl: nil, sampleRate: nil,
                      bitDepth: nil, codec: nil, isLossless: false)
    }

    @Test("persist then restore preserves queue state")
    func persistRestoreRoundTrip() throws {
        let c = try makeModelContainer(inMemory: true)
        let ctx = c.mainContext
        let q = QueueService()
        q.modelContext = ctx
        let ctx3 = [snap("a"), snap("b"), snap("c")]
        q.play(ctx3[1], context: ctx3, from: .album)
        q.persist()
        let q2 = QueueService()
        q2.modelContext = ctx
        q2.restore()
        #expect(q2.items.count == 3)
        #expect(q2.currentIndex == 1)
    }

    @Test("move preserves order through persist/restore")
    func moveOrderPersistRestore() throws {
        let c = try makeModelContainer(inMemory: true)
        let ctx = c.mainContext
        let q = QueueService()
        q.modelContext = ctx
        let ctx3 = [snap("a"), snap("b"), snap("c")]
        q.play(ctx3[0], context: ctx3, from: .album)
        q.move(from: 0, to: 2)
        q.persist()
        #expect(q.items.map(\.track.title) == ["b", "c", "a"])
        #expect(q.currentIndex == 2)
        let q2 = QueueService()
        q2.modelContext = ctx
        q2.restore()
        #expect(q2.items.map(\.track.title) == ["b", "c", "a"])
        #expect(q2.currentIndex == 2)
    }
}
