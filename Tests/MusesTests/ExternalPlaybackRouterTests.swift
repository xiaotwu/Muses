import Foundation
import Testing
@testable import Muses

@Suite("External playback entry") @MainActor
struct ExternalPlaybackRouterTests {
    @Test func acceptsOnlyUnambiguousVideoLinks() {
        for text in ["muses://play?v=abcdefghijk", "https://youtu.be/abcdefghijk",
                     "https://music.youtube.com/watch?v=abcdefghijk", "https://www.youtube.com/shorts/abcdefghijk"] {
            #expect(ExternalPlaybackRoute(url: URL(string: text)!) == .video("abcdefghijk"))
        }
        for text in ["muses://play?v=short", "muses://play?v=abcdefghijk&v=abcdefghijl",
                     "muses://play?v=abcdefghijk&trackId=bad", "https://evilyoutube.com/watch?v=abcdefghijk",
                     "https://youtube.com.evil.org/watch?v=abcdefghijk", "https://youtube.com/channel/abcdefghijk",
                     "https://user@youtube.com/watch?v=abcdefghijk", "https://youtube.com/playlist?list=abcdefghijk"] {
            #expect(ExternalPlaybackRoute(url: URL(string: text)!) == nil)
        }
        #expect(ExternalPlaybackRoute(url: URL(string: "muses://play?v=abcdefghijk&source=shortcuts")!) == nil)
        let id = UUID()
        #expect(ExternalPlaybackRoute(url: URL(string: "muses://play?trackId=\(id)")!) == .track(id))
    }

    @Test("App automation uses the same external route contract")
    func appIntentContract() throws {
        let source = try String(contentsOfFile: #filePath
            .replacingOccurrences(of: "Tests/MusesTests/ExternalPlaybackRouterTests.swift",
                                  with: "Sources/Muses/Services/Automation/PlayYouTubeLinkIntent.swift"),
            encoding: .utf8)
        #expect(source.contains("static let openAppWhenRun = true"))
        #expect(source.contains("ExternalPlaybackRoute(url: link)"))
        #expect(source.contains("muses"))
    }

    @Test func importLinksRejectForeignHostsAndMalformedVideoIDs() {
        for text in ["https://evilyoutube.com/watch?v=abcdefghijk", "https://example.com/playlist?list=PLtest",
                     "https://youtube.com/watch?v=short", "https://youtube.com/playlist?list=PLone&list=PLtwo"] {
            #expect(YouTubeImportURL(text) == nil)
        }
        #expect(YouTubeImportURL("https://music.youtube.com/watch?v=abcdefghijk&list=PLtest") == .playlist("PLtest"))
        #expect(YouTubeImportURL("https://youtu.be/abcdefghijk") == .video("abcdefghijk"))
    }

    @Test func latestRequestWinsAndDuplicatesCoalesce() async {
        let engine = RecordingEngine()
        let playback = PlaybackService(engine: engine, queue: QueueService())
        var pending: [String: CheckedContinuation<TrackSnapshot, any Error>] = [:]
        var resolutions = 0
        let router = ExternalPlaybackRouter(playback: playback) { route in
            guard case .video(let id) = route else { throw ExternalPlaybackRouter.RoutingError.notFound }
            resolutions += 1
            return try await withCheckedThrowingContinuation { pending[id] = $0 }
        }
        let first = URL(string: "muses://play?v=abcdefghijk")!
        router.open(first)
        for _ in 0..<100 where pending["abcdefghijk"] == nil { await Task.yield() }
        router.open(first)
        #expect(resolutions == 1)
        router.open(URL(string: "muses://play?v=abcdefghijl")!)
        for _ in 0..<100 where pending["abcdefghijl"] == nil { await Task.yield() }
        func track(_ id: String) -> TrackSnapshot {
            TrackSnapshot(id: UUID(), title: id, artist: "Artist", albumTitle: nil,
                          durationSeconds: 120, youTubeId: id, artworkUrl: nil,
                          sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false)
        }
        let latest = track("abcdefghijl")
        pending.removeValue(forKey: "abcdefghijl")?.resume(returning: latest)
        for _ in 0..<100 where playback.state.track?.id != latest.id { await Task.yield() }
        pending.removeValue(forKey: "abcdefghijk")?.resume(returning: track("abcdefghijk"))
        for _ in 0..<20 { await Task.yield() }
        #expect(playback.state.track?.id == latest.id)
        #expect(router.errorMessage == nil)
        playback.pause()
    }

    @Test("deep-linking an existing library item keeps the active queue context")
    func existingTrackKeepsQueueContext() async {
        let engine = RecordingEngine()
        let queue = QueueService()
        let playback = PlaybackService(engine: engine, queue: queue)
        let first = makeTrack("first123456")
        let second = makeTrack("second12345")
        queue.play(first, context: [first, second], from: .songs)
        let router = ExternalPlaybackRouter(playback: playback) { route in
            guard case .track = route else { throw ExternalPlaybackRouter.RoutingError.notFound }
            return second
        }
        router.open(URL(string: "muses://play?trackId=\(second.id.uuidString)")!)
        for _ in 0..<100 where playback.queue.current()?.track.id != second.id { await Task.yield() }
        #expect(playback.queue.items.map(\.track.id) == [first.id, second.id])
        #expect(playback.queue.current()?.track.id == second.id)
        playback.pause()
    }

    @Test("deep-linking the current paused item resumes without mutating queue state")
    func currentTrackResumesWithoutQueueMutation() async {
        let engine = RecordingEngine()
        let queue = QueueService()
        let playback = PlaybackService(engine: engine, queue: queue)
        let first = makeTrack("first123456")
        let second = makeTrack("second12345")
        let upNext = makeTrack("upnext12345")
        queue.play(first, context: [first, second], from: .songs)
        queue.addToQueue(upNext)
        playback.playTrack(first, context: [first, second], from: .songs)
        playback.pause()
        let originalItemIDs = queue.items.map(\.id)
        let originalUpNextIDs = queue.upNext.map(\.id)
        let router = ExternalPlaybackRouter(playback: playback) { _ in first }

        router.open(URL(string: "muses://play?trackId=\(first.id.uuidString)")!)
        for _ in 0..<100 where !playback.state.isPlaying { await Task.yield() }

        #expect(playback.state.isPlaying)
        #expect(queue.items.map(\.id) == originalItemIDs)
        #expect(queue.upNext.map(\.id) == originalUpNextIDs)
        #expect(queue.current()?.track.id == first.id)
        playback.pause()
    }

    private func makeTrack(_ videoID: String) -> TrackSnapshot {
        TrackSnapshot(id: UUID(), title: videoID, artist: "Artist", albumTitle: nil,
                      durationSeconds: 120, youTubeId: videoID, artworkUrl: nil,
                      sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false)
    }
}
