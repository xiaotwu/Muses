import Foundation
import Testing
@testable import Muses

@Suite("YouTube chapters")
struct YouTubeChapterTests {
    @Test("Markers reject invalid offsets and duplicate positions without inventing chapters")
    func markers() throws {
        let data = Data(#"{"id":"abcdefghijk","duration":90,"chapters":[{"title":"Second","start_time":30,"end_time":90},{"title":" Intro ","start_time":0},{"title":"Duplicate","start_time":30},{"title":"Invalid","start_time":-1},{"title":"Past end","start_time":90},{"title":" ","start_time":2}]}"#.utf8)
        let chapters = try YouTubeChapter.decode(data, expectedVideoID: "abcdefghijk")
        #expect(chapters.map(\.title) == ["Intro", "Second"])
        #expect(chapters.map(\.start) == [0, 30])
        #expect(chapters.last?.end == 90)
    }

    @Test("Different video and malformed metadata fail; absent chapters are a valid empty result")
    func identity() throws {
        let data = Data(#"{"id":"abcdefghijk"}"#.utf8)
        #expect(throws: (any Error).self) {
            try YouTubeChapter.decode(data, expectedVideoID: "otherVideo1")
        }
        #expect(try YouTubeChapter.decode(data, expectedVideoID: "abcdefghijk").isEmpty)
        #expect(throws: (any Error).self) {
            try YouTubeChapter.decode(Data("not json".utf8), expectedVideoID: "abcdefghijk")
        }
    }
}
