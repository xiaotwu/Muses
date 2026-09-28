import Testing
import Foundation
import SwiftData
@testable import Muses

@MainActor
@Suite("QueueServicePersistence")
struct QueueServicePersistenceTests {
    private enum SaveError: Error { case injected }
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

    @Test("turning shuffle off after restart restores collection order")
    func shuffledOrderSurvivesRestart() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = container.mainContext
        let tracks = [snap("a"), snap("b"), snap("c"), snap("d")]
        let queue = QueueService()
        queue.modelContext = context
        queue.play(tracks[1], context: tracks, from: .album)
        queue.toggleShuffle()

        let restored = QueueService()
        restored.modelContext = context
        restored.restore()
        #expect(restored.shuffle)
        restored.toggleShuffle()
        #expect(restored.items.map(\.track.title) == ["a", "b", "c", "d"])
        #expect(restored.current()?.track.id == tracks[1].id)
    }

    @Test("turning shuffle off does not restore a removed entry")
    func removedItemStaysRemovedAfterShuffle() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = container.mainContext
        let tracks = [snap("a"), snap("b"), snap("c"), snap("d")]
        let queue = QueueService()
        queue.modelContext = context
        queue.play(tracks[1], context: tracks, from: .album)
        queue.toggleShuffle()
        let removed = queue.items.firstIndex { $0.track.id == tracks[2].id }!
        queue.removeItem(at: removed)

        let restored = QueueService()
        restored.modelContext = context
        restored.restore()
        restored.toggleShuffle()
        #expect(restored.items.map(\.track.title) == ["a", "b", "d"])
        #expect(restored.current()?.track.id == tracks[1].id)
    }

    @Test("failed save is visible and retry persists the in-memory queue")
    func saveFailureAndRetry() throws {
        let container = try makeModelContainer(inMemory: true)
        var shouldFail = true
        let queue = QueueService(saveContext: { context in
            if shouldFail { throw SaveError.injected }
            try context.save()
        })
        queue.modelContext = container.mainContext
        let track = snap("a")
        queue.play(track, context: [track], from: .album)
        #expect(queue.persistenceFailed)
        shouldFail = false
        queue.persist()
        #expect(!queue.persistenceFailed)

        let restored = QueueService()
        restored.modelContext = container.mainContext
        restored.restore()
        #expect(restored.current()?.track.id == track.id)
    }

    @Test("corrupt saved queue does not silently restore an empty collection")
    func corruptSnapshotReportsFailure() throws {
        let container = try makeModelContainer(inMemory: true)
        let queue = QueueService()
        queue.modelContext = container.mainContext
        let track = snap("a")
        queue.play(track, context: [track], from: .album)
        let context = ModelContext(container)
        let row = try #require(context.fetch(FetchDescriptor<QueueState>()).first)
        row.itemsJSON = "not-json"
        try context.save()

        let restored = QueueService()
        restored.modelContext = container.mainContext
        restored.restore()
        #expect(restored.persistenceFailed)
        #expect(restored.items.isEmpty)
    }

    @Test("corrupt shuffle order is reported without partially restoring queue")
    func corruptOrderReportsFailure() throws {
        let container = try makeModelContainer(inMemory: true)
        let queue = QueueService()
        queue.modelContext = container.mainContext
        let track = snap("a")
        queue.play(track, context: [track], from: .album)
        let context = ModelContext(container)
        let row = try #require(context.fetch(FetchDescriptor<QueueState>()).first)
        row.originalOrderIDsJSON = "not-json"
        try context.save()

        let restored = QueueService()
        restored.modelContext = container.mainContext
        restored.restore()
        #expect(restored.persistenceFailed)
        #expect(restored.items.isEmpty)
    }
}
