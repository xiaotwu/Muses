import Foundation
import Testing
@testable import Muses

@Suite("Resolved stream duration")
struct StreamDurationPolicyTests {
    @Test func exactSourceDuration() throws {
        let source = try #require(URL(string: "https://rr1.googlevideo.com/videoplayback?dur=233.478&itag=140"))
        #expect(StreamDurationPolicy.sourceDuration(source) == 233.478)
    }
    @Test func rejectsUntrustedInvalidAndAmbiguousDurations() throws {
        for value in [
            "https://example.com/videoplayback?dur=1",
            "https://googlevideo.com.example.com/videoplayback?dur=1",
            "http://rr1.googlevideo.com/videoplayback?dur=1",
            "https://rr1.googlevideo.com/videoplayback?dur=nan",
            "https://rr1.googlevideo.com/videoplayback?dur=inf",
            "https://rr1.googlevideo.com/videoplayback?dur=-1",
            "https://rr1.googlevideo.com/videoplayback?dur=0",
            "https://rr1.googlevideo.com/videoplayback?dur=1&dur=2",
            "https://rr1.googlevideo.com/videoplayback"
        ] {
            #expect(StreamDurationPolicy.sourceDuration(try #require(URL(string: value))) == nil)
        }
    }
}
