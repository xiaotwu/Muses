import Testing
import Foundation
@testable import Muses

@MainActor
@Suite("QueueService")
struct QueueServiceTests {
    private func snap(_ t: String) -> TrackSnapshot {
        TrackSnapshot(id: UUID(), title: t, artist: "a", albumTitle: nil,
                      durationSeconds: 1, filePath: nil, youTubeId: nil,
                      artworkHash: nil, artworkUrl: nil, sampleRate: nil,
                      bitDepth: nil, codec: nil, isLossless: false)
    }

    @Test("play sets context and positions index")
    func playContext() {
        let q = QueueService()
        let ctx = [snap("a"), snap("b"), snap("c")]
        q.play(ctx[1], context: ctx, from: .album)
        #expect(q.items.count == 3)
        #expect(q.currentIndex == 1)
        #expect(q.current()?.track.title == "b")
    }

    @Test("playNext inserts to upNext head")
    func playNextInsert() {
        let q = QueueService()
        let ctx = [snap("a")]
        q.play(ctx[0], context: ctx, from: .album)
        q.playNext(snap("x"))
        q.playNext(snap("y"))
        #expect(q.upNext.count == 2)
        #expect(q.upNext.first?.track.title == "y")
    }

    @Test("next drains upNext then context, writes history")
    func nextDrainsUpNext() {
        let q = QueueService()
        let ctx = [snap("a"), snap("b")]
        q.play(ctx[0], context: ctx, from: .album)
        q.playNext(snap("x"))
        let n1 = q.next()
        #expect(n1?.track.title == "x")
        #expect(q.history.first?.track.title == "a")
        #expect(q.upNext.isEmpty)
        let n2 = q.next()
        #expect(n2?.track.title == "b")
    }

    @Test("repeat one keeps current")
    func repeatOne() {
        let q = QueueService()
        let ctx = [snap("a"), snap("b")]
        q.play(ctx[0], context: ctx, from: .album)
        q.setRepeat(.one)
        let n = q.next()
        #expect(n?.track.title == "a")
    }

    @Test("repeat all wraps")
    func repeatAll() {
        let q = QueueService()
        let ctx = [snap("a"), snap("b")]
        q.play(ctx[1], context: ctx, from: .album)
        q.setRepeat(.all)
        _ = q.next()
        let n = q.next()
        #expect(n?.track.title == "a")
    }

    @Test("previous navigates history")
    func previous() {
        let q = QueueService()
        let ctx = [snap("a"), snap("b")]
        q.play(ctx[0], context: ctx, from: .album)
        _ = q.next()
        let p = q.previous()
        #expect(p?.track.title == "a")
    }
}