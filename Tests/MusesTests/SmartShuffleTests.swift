import Foundation
import SwiftData
import Testing
@testable import Muses

@Suite("Smart Shuffle collection semantics") @MainActor
struct SmartShuffleTests {
    private func track(_ index: Int) -> TrackSnapshot {
        .init(id: UUID(), title: "Song \(index)", artist: "Artist", albumTitle: nil,
              durationSeconds: 100, youTubeId: String(format: "%011d", index), artworkUrl: nil,
              sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false)
    }
    private func ready() -> QueueService {
        let queue = QueueService()
        let tracks = (0..<6).map(track)
        queue.play(tracks[0], context: tracks, from: .playlist)
        queue.setSmartShuffle(true)
        _ = queue.next(); _ = queue.next()
        return queue
    }
    private func stage(_ queue: QueueService, index: Int = 99) -> TrackSnapshot {
        let candidate = track(index)
        #expect(queue.stageRecommendation(candidate, sourceVideoID: queue.current()!.track.youTubeId, collectionID: queue.smartShuffle.collectionID))
        return candidate
    }

    @Test func defaultOffAndManualPriority() {
        #expect(!QueueService().smartShuffle.enabled)
        let queue = ready()
        let collection = queue.items.map(\.id)
        let candidate = stage(queue)
        let manual = track(88)
        queue.playNext(manual)
        #expect(queue.next()?.track.id == manual.id)
        #expect(queue.smartShuffle.collectionPlayed == 3)
        #expect(queue.next()?.track.id == candidate.id)
        #expect(queue.currentIndex == 2)
        #expect(queue.smartShuffle.collectionPlayed == 0)
        #expect(queue.next()?.id == collection[3])
        #expect(queue.items.map(\.id) == collection)
    }

    @Test func skipsAndPreviousDoNotInflateInterval() {
        let queue = ready()
        let candidate = stage(queue)
        #expect(queue.next(as: .skipped)?.id == queue.items[3].id)
        #expect(queue.smartShuffle.collectionPlayed == 2)
        _ = queue.previous()
        #expect(queue.next(as: .skipped)?.id == queue.items[3].id)
        #expect(queue.smartShuffle.collectionPlayed == 2)
        #expect(queue.next()?.track.id == candidate.id)
    }

    @Test func repeatOnePausesInsertionAndRepeatAllRetainsCollection() {
        let queue = ready()
        let candidate = stage(queue)
        let current = queue.current()?.id
        queue.setRepeat(.one)
        #expect(queue.peekNext()?.id == current)
        #expect(queue.next()?.id == current)
        #expect(queue.smartShuffle.collectionPlayed == 2)
        queue.setRepeat(.all)
        #expect(queue.next()?.track.id == candidate.id)
        #expect(queue.next()?.id == queue.items[3].id)
        _ = queue.next(); _ = queue.next()
        #expect(queue.next()?.id == queue.items[0].id)
    }

    @Test func disablingKeepsCurrentAndExplicitlyPromotedEntries() {
        let queue = ready()
        let candidate = stage(queue)
        #expect(queue.next()?.track.id == candidate.id)
        queue.setSmartShuffle(false)
        #expect(queue.current()?.track.id == candidate.id)
        #expect(queue.smartShuffle.pending == nil)
        _ = queue.next()
        #expect(queue.history.contains { $0.track.id == candidate.id })
        let other = ready()
        let promoted = stage(other)
        other.playNext(promoted)
        other.setSmartShuffle(false)
        #expect(other.upNext.first?.track.id == promoted.id)
        #expect(other.upNext.first?.recommendationSourceVideoID == nil)
    }

    @Test func duplicatesLateCollectionAndManualDuplicateAreRejected() {
        let queue = ready()
        #expect(!queue.stageRecommendation(queue.items[0].track, sourceVideoID: queue.current()!.track.youTubeId, collectionID: queue.smartShuffle.collectionID))
        #expect(!queue.stageRecommendation(track(99), sourceVideoID: queue.current()!.track.youTubeId, collectionID: UUID()))
        let candidate = stage(queue)
        queue.playNext(candidate)
        #expect(queue.next()?.track.id == candidate.id)
        #expect(queue.smartShuffle.pending == nil)
        #expect(queue.next()?.id == queue.items[3].id)
    }

    @Test func persistedRecommendationIsRestoredWithoutRegeneration() throws {
        let container = try makeModelContainer(inMemory: true)
        let queue = ready()
        queue.modelContext = container.mainContext
        let candidate = stage(queue)
        let pendingID = queue.smartShuffle.pending?.id
        let restored = QueueService()
        restored.modelContext = container.mainContext
        restored.restore()
        #expect(restored.smartShuffle.enabled)
        #expect(restored.smartShuffle.pending?.id == pendingID)
        #expect(restored.smartShuffle.pending?.recommendationSourceVideoID == queue.current()?.track.youTubeId)
        #expect(restored.next()?.track.id == candidate.id)
        #expect(restored.currentIndex == 2)
        let again = QueueService()
        again.modelContext = container.mainContext
        again.restore()
        #expect(again.current()?.track.id == candidate.id)
        #expect(again.next()?.id == again.items[3].id)
    }

    @Test func oldQueueDefaultsToDisabled() throws {
        let container = try makeModelContainer(inMemory: true)
        let queue = ready()
        queue.modelContext = container.mainContext
        queue.persist()
        let row = try #require(container.mainContext.fetch(FetchDescriptor<QueueState>()).first)
        row.smartShuffleJSON = nil
        try container.mainContext.save()
        let restored = QueueService()
        restored.modelContext = container.mainContext
        restored.restore()
        #expect(!restored.smartShuffle.enabled)
        #expect(restored.smartShuffle.pending == nil)
        #expect(restored.items.count == 6)
    }
}
