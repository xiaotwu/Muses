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
        let coordinator = YouTubeWKEmbed.Coordinator()
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
}
