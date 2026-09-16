import Foundation
import Testing
@testable import Muses

@Suite("Recording-aware lyrics")
struct LyricsMatchingTests {
    private func track(title: String = "Evening Light (Official Music Video)", artist: String = "Example Artist", duration: Double = 180) -> TrackSnapshot {
        TrackSnapshot(id: UUID(), title: title, artist: artist, albumTitle: nil,
                      durationSeconds: duration, youTubeId: "test_video", artworkUrl: nil,
                      sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false)
    }

    private func candidate(id: Int = 1, title: String = "Evening Light", artist: String = "Example Artist", duration: Double? = 180, text: String = "A synthetic lyric for a test") -> LyricsCandidate {
        LyricsCandidate(id: id, trackName: title, artistName: artist, albumName: nil,
                        duration: duration, instrumental: false, plainLyrics: text, syncedLyrics: nil)
    }

    @Test("Search order cannot select a different artist or recording")
    func recordingIdentity() {
        let wrongArtist = candidate(id: 2, artist: "Other Artist")
        let wrongDuration = candidate(id: 3, duration: 240)
        let live = candidate(id: 4, title: "Evening Light (Live)")
        let correct = candidate()
        #expect(LyricsMatchPolicy.automatic([wrongArtist, wrongDuration, live, correct], track: track())?.id == 1)
        #expect(LyricsMatchPolicy.automatic([wrongArtist, wrongDuration, live], track: track()) == nil)
    }

    @Test("Unknown duration and ambiguous competing texts require a choice")
    func uncertainty() {
        #expect(LyricsMatchPolicy.automatic([candidate(duration: nil)], track: track()) == nil)
        #expect(LyricsMatchPolicy.automatic([candidate(), candidate(id: 2, text: "Different synthetic text")], track: track()) == nil)
        #expect(LyricsMatchPolicy.automatic([candidate(), candidate(id: 2)], track: track()) != nil)
    }

    @Test("YouTube artist prefixes and Topic suffixes do not prevent matching")
    func decorations() {
        #expect(LyricsMatchPolicy.automatic([candidate()], track: track(title: "Example Artist - Evening Light (Official Video)", artist: "Example Artist - Topic"))?.id == 1)
        #expect(LyricsService.queryTitles("Example Artist - Evening Light (Official Video)", artist: "Example Artist - Topic").first == "Evening Light")
        #expect(LyricsMatchPolicy.queryArtist("Example Artist - Topic") == "Example Artist")
        #expect(LyricsService.queryTitles("Other Artist - Evening Light", artist: "Example Artist").first == "Other Artist - Evening Light")
    }

    @Test("Translated repeated lines are aligned by index, never by text")
    func alignment() {
        #expect(LyricsLineAlignment.align([(1, "Repeated"), (0, "Repeated")], count: 2) == ["Repeated", "Repeated"])
        #expect(LyricsLineAlignment.align([(0, "One"), (0, "Two")], count: 2) == nil)
        #expect(LyricsLineAlignment.align([(0, "One")], count: 2) == nil)
        #expect(LyricsLineAlignment.align([(0, "One"), (2, "Two")], count: 2) == nil)
    }

    @Test("Lyric cache retains source and does not collide across recording metadata")
    func cache() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LyricsDocumentCache(directory: directory)
        let original = track()
        let key = LyricsDocumentIdentity.key(for: original)
        let result = LyricsResult(plainLyrics: "Synthetic test", syncedLyrics: nil, source: .lrclib)
        await cache.write(result, key: key)
        #expect(await cache.read(key: key)?.source == .lrclib)
        #expect(await cache.read(key: LyricsDocumentIdentity.key(for: track(title: "Evening Light (Live)"))) == nil)
        #expect(await cache.read(key: "../outside") == nil)
    }
    @MainActor
    @Test("plain cache upgrades only to identical text with trustworthy recording timing")
    func synchronizedCacheUpgrade() {
        let original = track()
        let cached = LyricsResult(plainLyrics: "First line\nSecond line", syncedLyrics: nil, source: .cached)
        func timed(_ text: String, duration: Double = 180) -> LyricsCandidate {
            LyricsCandidate(id: 99, trackName: "Evening Light", artistName: "Example Artist",
                            albumName: nil, duration: duration, instrumental: false,
                            plainLyrics: "First line\nSecond line", syncedLyrics: text)
        }
        let valid = timed("[00:12.00]First line\n[00:17.50]Second line")
        #expect(LyricsSyncUpgrade.match(cached, candidates: [valid], track: original)?.id == 99)
        #expect(LyricsSyncUpgrade.match(cached, candidates: [timed("First line\nSecond line")], track: original) == nil)
        #expect(LyricsSyncUpgrade.match(cached, candidates: [timed("[00:12]Different lyrics")], track: original) == nil)
        #expect(LyricsSyncUpgrade.match(cached, candidates: [timed("[00:12]First line\n[00:17]Second line", duration: 250)], track: original) == nil)
    }

}
