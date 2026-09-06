import Testing
import Foundation
import SwiftData
@testable import Muses

/// Advanced Lyrics acceptance (Final Spec §10.8 Feature 8):
/// - enhanced LRC word-level `<mm:ss.xx>` timestamps parsed into `LyricWord`;
/// - LRC `[offset:±ms]` parsing + the offset applied to current-line detection and click-to-seek;
/// - `Track.lyricsOffsetMs` manual offset persistence + `LyricsService.manualOffsetMs` observability;
/// - fallback chain word → line → plain (no word data → words = nil; no timestamps → time = nil).
@MainActor
@Suite("Phase 22 Advanced Lyrics")
struct LyricsTimingTests {

    private func makeContainer() throws -> ModelContainer {
        try makeModelContainer(inMemory: true)
    }

    // MARK: - Word-level parsing

    @Test("Enhanced LRC inline `<mm:ss.xx>` parses to LyricWord with last word end=nil")
    func wordTimingParsed() throws {
        // Line starts at 1.0s; "Hello " starts at 1.0, "world " at 1.5, "foo" at 2.0 (last word).
        let lrc = "[00:01.00]Hello <00:01.50>world <00:02.00>foo"
        let lines = LyricsService.parseLRC(lrc)
        #expect(lines.count == 1)
        let line = lines[0]
        #expect(line.time == 1.0)
        #expect(line.text.contains("Hello"))
        let words = try #require(line.words)
        #expect(words.count == 3)
        #expect(words[0].text == "Hello ")
        #expect(words[0].start == 1.0)
        #expect(words[0].end == 1.5)        // = the next word's start
        #expect(words[1].text == "world ")
        #expect(words[1].start == 1.5)
        #expect(words[1].end == 2.0)
        #expect(words[2].text == "foo")
        #expect(words[2].start == 2.0)
        #expect(words[2].end == nil)        // last word has end = nil
    }

    @Test("Plain line-level LRC without inline tags has words=nil and falls back to line highlighting")
    func plainLineLevelWordsNil() {
        let lrc = "[00:10.00]a plain line\n[00:20.00]another"
        let lines = LyricsService.parseLRC(lrc)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.words == nil })
        #expect(lines[0].time == 10.0)
    }

    // MARK: - offset parsing

    @Test("parseOffsetMs extracts [offset:+-ms], returning nil when absent")
    func offsetParsed() {
        #expect(LyricsService.parseOffsetMs("[offset:250]abc") == 250)
        #expect(LyricsService.parseOffsetMs("[offset:-500]\n[00:01.00]hi") == -500)
        #expect(LyricsService.parseOffsetMs("[00:01.00]no offset tag") == nil)
        #expect(LyricsService.parseOffsetMs("") == nil)
    }

    @Test("fetchCached populates LyricsResult.offsetMs from LRC cache containing [offset:]")
    func cachedOffsetPropagated() {
        let lrc = "[offset:-300]\n[00:01.00]line"
        let snap = TrackSnapshot(id: UUID(), title: "T", artist: "A",
                                 albumTitle: nil, durationSeconds: 1,
                                 youTubeId: "test-video",                                  artworkUrl: nil, sampleRate: nil, bitDepth: nil,
                                 codec: nil, isLossless: false, lyrics: lrc)
        let svc = LyricsService()
        let result = svc.fetchCached(track: snap)
        #expect(result?.offsetMs == -300)
        #expect(result?.syncedLyrics != nil)
    }

    // MARK: - Offset applied to current-line detection

    @Test("currentLineIndex: positive offset delays line activation, negative advances it")
    func offsetShiftsCurrentLine() {
        let lrc = "[00:10.00]first\n[00:20.00]second"
        let lines = LyricsService.parseLRC(lrc)

        // No offset: position 15 → first line; 25 → second line
        #expect(LyricsView.currentLineIndex(in: lines, at: 15, offset: 0) == 0)
        #expect(LyricsView.currentLineIndex(in: lines, at: 25, offset: 0) == 1)

        // Positive offset +2s: a line activates at time + offset. position = 11 < 10 + 2 = 12 → nil (first line not reached yet)
        #expect(LyricsView.currentLineIndex(in: lines, at: 11, offset: 2) == nil)
        #expect(LyricsView.currentLineIndex(in: lines, at: 12, offset: 2) == 0)
        #expect(LyricsView.currentLineIndex(in: lines, at: 23, offset: 2) == 1)

        // Negative offset -2s: the first line activates at 8s
        #expect(LyricsView.currentLineIndex(in: lines, at: 8, offset: -2) == 0)
    }

    // MARK: - Active word index

    @Test("currentWordIndex selects closest word in line where start+offset <= position")
    func currentWordIndexPicksActive() {
        let words = [
            LyricWord(id: UUID(), text: "a", start: 1.0, end: 1.5),
            LyricWord(id: UUID(), text: "b", start: 1.5, end: 2.0),
            LyricWord(id: UUID(), text: "c", start: 2.0, end: nil),
        ]
        #expect(LyricsView.currentWordIndex(in: words, at: 1.0) == 0)
        #expect(LyricsView.currentWordIndex(in: words, at: 1.6) == 1)
        #expect(LyricsView.currentWordIndex(in: words, at: 2.5) == 2)
        #expect(LyricsView.currentWordIndex(in: words, at: 0.9) == nil)
    }

    // MARK: - Manual offset persistence + observability

    @Test("setOffset persists to Track.lyricsOffsetMs and updates manualOffsetMs, clearing on 0")
    func setOffsetPersistsAndObservable() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let track = Track(title: "Offset Song", artist: "A", durationMs: 200000, youTubeId: "test-video")
        ctx.insert(track)
        try ctx.save()

        let svc = LyricsService(modelContainer: container)
        #expect(svc.manualOffsetMs == 0)

        svc.setOffset(trackId: track.id, offsetMs: 250)
        #expect(svc.manualOffsetMs == 250)
        let fetched = (try ctx.fetch(FetchDescriptor<Track>())).first(where: { $0.id == track.id })!
        #expect(fetched.lyricsOffsetMs == 250)

        // Zeroing it → store nil, observable resets to zero
        svc.setOffset(trackId: track.id, offsetMs: 0)
        #expect(svc.manualOffsetMs == 0)
        let after = (try ctx.fetch(FetchDescriptor<Track>())).first(where: { $0.id == track.id })!
        #expect(after.lyricsOffsetMs == nil)
    }

    @Test("TrackSnapshot(from:) carries lyricsOffsetMs")
    func snapshotFromTrackCarriesOffset() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let track = Track(title: "Carry", artist: "A", durationMs: 100000, youTubeId: "test-video")
        track.lyricsOffsetMs = -150
        ctx.insert(track); try ctx.save()
        let snap = TrackSnapshot(from: track)
        #expect(snap.lyricsOffsetMs == -150)
    }

    // MARK: - Fallback chain word → line → plain (existing behavior preserved)

    @Test("Existing parseLRC behavior preserved: multiple tags, metadata skip, untimed lines last")
    func existingParseLRCPreserved() {
        let lrc = """
        [ti:Title]
        [01:23.45][02:45.67] shared lyric
        plain text no time
        """
        let lines = LyricsService.parseLRC(lrc)
        #expect(lines.count == 3)
        #expect(lines[0].time == 83.45 && lines[0].text == "shared lyric")
        #expect(lines[1].time == 165.67 && lines[1].text == "shared lyric")
        #expect(lines[2].time == nil && lines[2].text == "plain text no time")
    }
}
