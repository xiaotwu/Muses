import Foundation
import Testing
@testable import Muses

@Suite("Official YouTube sharing")
struct YouTubeSharingTests {
    @Test("Canonical links remove tracking and preserve resource identity")
    func canonical() throws {
        let target = try #require(YouTubeShareTarget(url: URL(string: "https://youtu.be/video_123?si=tracking&t=123")!))
        #expect(target.url(on: .music)?.absoluteString == "https://music.youtube.com/watch?v=video_123")
        #expect(target.url(on: .youtube)?.absoluteString == "https://www.youtube.com/watch?v=video_123")
        let playlist = try #require(YouTubeShareTarget(url: URL(string: "https://music.youtube.com/playlist?list=PL_test&si=tracking")!))
        #expect(playlist.url(on: .youtube)?.absoluteString == "https://www.youtube.com/playlist?list=PL_test")
    }

    @Test("Foreign URLs, search pages, ambiguous IDs and path injection cannot be shared as content")
    func invalid() {
        for raw in ["https://youtube.com.evil.test/watch?v=x", "http://youtube.com/watch?v=x", "https://music.youtube.com/search?q=artist", "https://youtube.com/watch?v=x&v=y", "https://user@youtube.com/watch?v=x"] {
            #expect(YouTubeShareTarget(url: URL(string: raw)!) == nil)
        }
        #expect(YouTubeShareTarget(kind: .video, id: "x&secret=value") == nil)
        #expect(YouTubeShareTarget(kind: .playlist, id: "../local") == nil)
    }

    @Test("Social compose links contain only the chosen official URL")
    func platforms() throws {
        let target = try #require(YouTubeShareTarget(kind: .video, id: "video_123"))
        for platform in YouTubeShareTarget.Platform.allCases {
            let url = try #require(target.platformURL(platform, service: .music))
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.count == 1)
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == target.url(on: .music)?.absoluteString)
        }
        #expect(YouTubeShareTarget(kind: .browse, id: "MPRE_test")?.url(on: .youtube) == nil)
    }
}
