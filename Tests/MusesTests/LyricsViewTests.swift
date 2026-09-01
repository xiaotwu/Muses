import Testing
import Foundation
@testable import Muses

@Suite("LyricsView")
struct LyricsViewTests {

    /// currentLineIndex returns the last line whose time <= position.
    @Test("currentLineIndex 定位当前行")
    func currentLineIndexBasic() {
        let lines = [
            LyricLine(id: UUID(), time: 0.0, text: "intro"),
            LyricLine(id: UUID(), time: 5.0, text: "first"),
            LyricLine(id: UUID(), time: 10.0, text: "second"),
            LyricLine(id: UUID(), time: 20.0, text: "third"),
        ]
        #expect(LyricsView.currentLineIndex(in: lines, at: 0.0) == 0)
        #expect(LyricsView.currentLineIndex(in: lines, at: 3.0) == 0)
        #expect(LyricsView.currentLineIndex(in: lines, at: 5.0) == 1)
        #expect(LyricsView.currentLineIndex(in: lines, at: 12.0) == 2)
        #expect(LyricsView.currentLineIndex(in: lines, at: 25.0) == 3)
    }

    /// Returns nil when position precedes the first line's timestamp (no line reached yet).
    @Test("currentLineIndex 在首行之前返回 nil")
    func currentLineIndexBeforeFirst() {
        let lines = [
            LyricLine(id: UUID(), time: 10.0, text: "first"),
            LyricLine(id: UUID(), time: 20.0, text: "second"),
        ]
        #expect(LyricsView.currentLineIndex(in: lines, at: 5.0) == nil)
    }

    /// Plain-text lyrics (time == nil) do not affect currentLineIndex.
    @Test("currentLineIndex 跳过无时间标签行")
    func currentLineIndexSkipsNilTime() {
        let lines = [
            LyricLine(id: UUID(), time: 5.0, text: "timed"),
            LyricLine(id: UUID(), time: nil, text: "untimed"),
            LyricLine(id: UUID(), time: 10.0, text: "timed2"),
        ]
        #expect(LyricsView.currentLineIndex(in: lines, at: 7.0) == 0)
        #expect(LyricsView.currentLineIndex(in: lines, at: 12.0) == 2)
    }
}