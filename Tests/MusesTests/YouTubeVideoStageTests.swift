import Foundation
import Testing
@testable import Muses

@MainActor
@Suite("YouTubeVideoStage")
struct YouTubeVideoStageTests {
    @Test("embed HTML enables commands and changes with the supplied video ID")
    func embedHTMLTracksVideoIdentity() {
        let first = YouTubeEmbed.pageHTML(videoId: "video-A")
        let second = YouTubeEmbed.pageHTML(videoId: "video-B")

        #expect(first.contains("/embed/video-A?"))
        #expect(second.contains("/embed/video-B?"))
        #expect(!second.contains("/embed/video-A?"))
        #expect(first.contains("enablejsapi=1"))
    }

    @Test("coordinator reloads only for a new ID and invalidates stale navigation")
    func coordinatorScopesNavigationToVideoIdentity() throws {
        let coordinator = YouTubeWKEmbed.PlayerCoordinator()
        let firstGeneration = try #require(coordinator.beginNavigation(to: "video-A"))
        #expect(coordinator.owns(videoId: "video-A", generation: firstGeneration))
        #expect(coordinator.beginNavigation(to: "video-A") == nil)

        let secondGeneration = try #require(coordinator.beginNavigation(to: "video-B"))
        #expect(secondGeneration > firstGeneration)
        #expect(!coordinator.owns(videoId: "video-A", generation: firstGeneration))
        #expect(coordinator.owns(videoId: "video-B", generation: secondGeneration))

        coordinator.invalidate()
        #expect(!coordinator.owns(videoId: "video-B", generation: secondGeneration))
    }
    @Test("video handoff preserves a paused position and does not resume native audio")
    func pausedHandoff() {
        let engine = RecordingEngine()
        let playback = PlaybackService(engine: engine, queue: QueueService())
        engine.state.track = TrackSnapshot(
            id: UUID(), title: "Video", artist: "Artist", albumTitle: nil,
            durationSeconds: 200, youTubeId: "video00000a", artworkUrl: nil,
            sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false)
        engine.state.position = 64.25
        let savedVolume = playback.volume
        defer { playback.setVolume(savedVolume) }
        playback.setVolume(0.52)
        playback.pause()
        let start = playback.videoPlaybackStart(for: "video00000a")
        let suspension = playback.beginNativePlaybackSuspension()
        #expect(start.position == 64.25)
        #expect(!start.shouldPlay)
        #expect(start.volumePercent == 52)
        #expect(!engine.state.isPlaying)
        #expect(playback.videoPlaybackStart(for: "video00000b").position == 0)
        #expect(!playback.videoPlaybackStart(for: "video00000b").shouldPlay)
        playback.endNativePlaybackSuspension(suspension, resume: true)
        #expect(!engine.state.isPlaying)

        playback.play()
        let playingStart = playback.videoPlaybackStart(for: "video00000a")
        let playingSuspension = playback.beginNativePlaybackSuspension()
        #expect(playingStart.shouldPlay)
        #expect(!engine.state.isPlaying)
        playback.endNativePlaybackSuspension(playingSuspension, resume: true)
        #expect(engine.state.isPlaying)
        playback.pause()
    }

    @Test("start values reject invalid numbers and choose cue versus play after volume")
    func safeStartValues() {
        let invalid = VideoPlaybackStart(position: .nan, volume: .infinity)
        #expect(invalid.position == 0)
        #expect(invalid.volumePercent == 0)
        #expect(VideoPlaybackStart(position: -1, volume: 2).volumePercent == 100)
        #expect(VideoPlaybackStart(position: -1).position == 0)
        let paused = YouTubeEmbed.pageHTML(videoId: "video00000a",
            start: VideoPlaybackStart(position: 64.25, shouldPlay: false, volume: 0.52))
        #expect(paused.contains("autoplay=0&start=64"))
        #expect(paused.contains("startSeconds: 64.25"))
        #expect(paused.contains("player.cueVideoById"))
        #expect(!paused.contains("player.loadVideoById"))
        #expect(paused.contains("player.setVolume(52)"))
        let playing = YouTubeEmbed.pageHTML(videoId: "video00000a",
            start: VideoPlaybackStart(position: 64.25, shouldPlay: true, volume: 0.52))
        #expect(playing.contains("player.loadVideoById"))
    }

    @Test("video fits short and wide windows without shifting its center for chrome")
    func centeredVideoLayout() {
        for available in [CGSize(width: 1600, height: 1000), CGSize(width: 1400, height: 450), CGSize(width: 500, height: 700)] {
            let size = VideoOverlayLayout.videoSize(in: available)
            #expect(size.width <= available.width - 48)
            #expect(size.height <= available.height - 48)
            #expect(abs(size.width / size.height - 16.0 / 9.0) < 0.001)
        }
    }

}
