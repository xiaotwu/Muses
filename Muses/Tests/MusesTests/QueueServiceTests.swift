import Testing
import Foundation
@testable import Muses

@MainActor
@Suite("QueueService")
struct QueueServiceTests {
    private func snap(_ t: String) -> TrackSnapshot {
        TrackSnapshot(id: UUID(), title: t, artist: "a", albumTitle: nil,
                      durationSeconds: 1, youTubeId: "test-video",
                      artworkUrl: nil, sampleRate: nil,
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
        #expect(q.currentIndex == 0)
        #expect(q.current()?.track.title == "a")
    }

    @Test("turning shuffle off keeps the playing track as current")
    func shuffleOffKeepsCurrentTrack() {
        let q = QueueService()
        let ctx = [snap("a"), snap("b"), snap("c")]
        q.play(ctx[1], context: ctx, from: .album)
        q.toggleShuffle()
        #expect(q.current()?.track.title == "b")
        q.toggleShuffle()
        #expect(q.current()?.track.title == "b")
        #expect(q.currentIndex == 1)
        #expect(q.items.map(\.track.title) == ["a", "b", "c"])
    }

    @Test("peekNext follows collection then wraps on repeat all")
    func peekNextFollowsCollection() {
        let q = QueueService()
        let ctx = [snap("a"), snap("b"), snap("c")]
        q.play(ctx[1], context: ctx, from: .album)
        #expect(q.peekNext()?.track.title == "c")
        q.play(ctx[2], context: ctx, from: .album)
        #expect(q.peekNext() == nil)
        q.setRepeat(.all)
        #expect(q.peekNext()?.track.title == "a")
        q.playNext(snap("x"))
        #expect(q.peekNext()?.track.title == "x")
    }

    @Test("recently-played context keeps full list and tapped index")
    func recentlyPlayedFullContext() {
        let q = QueueService()
        let ctx = [snap("a"), snap("b"), snap("c")]
        q.play(ctx[1], context: ctx, from: .recently)
        #expect(q.items.count == 3)
        #expect(q.currentIndex == 1)
        #expect(q.current()?.track.title == "b")
        let n = q.next()
        #expect(n?.track.title == "c")
    }

    @Test("playlist context of three snaps positions last tap at index 2")
    func playlistFullContext() {
        let q = QueueService()
        let ctx = [snap("a"), snap("b"), snap("c")]
        q.play(ctx[2], context: ctx, from: .playlist)
        #expect(q.items.count == 3)
        #expect(q.currentIndex == 2)
        #expect(q.current()?.track.title == "c")
    }
}
