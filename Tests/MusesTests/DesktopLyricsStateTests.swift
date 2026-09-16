import Foundation
import Testing
@testable import Muses

@MainActor
@Suite("Desktop lyrics states")
struct DesktopLyricsStateTests {
    @Test("instrumental intro is distinct from unsynced, loading and absent lyrics")
    func distinguishesFallbackStates() {
        let timed = [LyricLine(id: UUID(), time: 12, text: "First line")]
        let plain = [LyricLine(id: UUID(), time: nil, text: "Plain text")]
        let intro = DesktopLyricsOverlayView.displayText(lines: timed, at: 0)
        let unsynced = DesktopLyricsOverlayView.displayText(lines: plain, at: 0)
        let missing = DesktopLyricsOverlayView.displayText(lines: nil, at: 0)
        let loading = DesktopLyricsOverlayView.displayText(lines: nil, at: 0, isLoading: true)
        #expect(Set([intro, unsynced, missing, loading]).count == 4)
        #expect(DesktopLyricsOverlayView.displayText(lines: timed, at: 12) == "First line")
        #expect(DesktopLyricsOverlayView.displayText(lines: timed, at: 12, offset: 2) == intro)
        #expect(DesktopLyricsOverlayView.displayText(lines: timed, at: 14, offset: 2) == "First line")
        #expect(DesktopLyricsOverlayView.displayText(lines: [], at: 0) == missing)
    }
}
