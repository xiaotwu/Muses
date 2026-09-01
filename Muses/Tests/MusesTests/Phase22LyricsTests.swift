import Testing
import Foundation
import SwiftData
@testable import Muses

/// Phase 22 — Advanced Lyrics 验收(对应 Final Spec §10.8 Feature 8):
/// - 增强 LRC 逐词时间 `<mm:ss.xx>` 解析为 `LyricWord`;
/// - LRC `[offset:±ms]` 解析 + 偏移作用于当前行检测与点击跳转;
/// - `Track.lyricsOffsetMs` 手动偏移持久化 + `LyricsService.manualOffsetMs` 可观察;
/// - 回退链 word→line→plain(无逐词数据 words=nil;无时间标签 time=nil)。
@MainActor
@Suite("Phase 22 Advanced Lyrics")
struct Phase22LyricsTests {

    private func makeContainer() throws -> ModelContainer {
        try makeModelContainer(inMemory: true)
    }

    // MARK: - 逐词解析

    @Test("增强 LRC 内联 `<mm:ss.xx>` 解析为 LyricWord,末词 end=nil")
    func wordTimingParsed() throws {
        // 行起点 1.0s;词 "Hello " 起 1.0、"world " 起 1.5、"foo" 起 2.0(末词)。
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
        #expect(words[0].end == 1.5)        // = 下一词 start
        #expect(words[1].text == "world ")
        #expect(words[1].start == 1.5)
        #expect(words[1].end == 2.0)
        #expect(words[2].text == "foo")
        #expect(words[2].start == 2.0)
        #expect(words[2].end == nil)        // 末词 end=nil
    }

    @Test("普通行级 LRC(无内联标签)words=nil,回退行级高亮")
    func plainLineLevelWordsNil() {
        let lrc = "[00:10.00]a plain line\n[00:20.00]another"
        let lines = LyricsService.parseLRC(lrc)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.words == nil })
        #expect(lines[0].time == 10.0)
    }

    // MARK: - offset 解析

    @Test("parseOffsetMs 提取 [offset:±ms],无标签返回 nil")
    func offsetParsed() {
        #expect(LyricsService.parseOffsetMs("[offset:250]abc") == 250)
        #expect(LyricsService.parseOffsetMs("[offset:-500]\n[00:01.00]hi") == -500)
        #expect(LyricsService.parseOffsetMs("[00:01.00]no offset tag") == nil)
        #expect(LyricsService.parseOffsetMs("") == nil)
    }

    @Test("fetchCached 从含 [offset:] 的 LRC 缓存填充 LyricsResult.offsetMs")
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

    // MARK: - 偏移作用于当前行检测

    @Test("currentLineIndex offset 正值→歌词更晚激活;负值→更早")
    func offsetShiftsCurrentLine() {
        let lrc = "[00:10.00]first\n[00:20.00]second"
        let lines = LyricsService.parseLRC(lrc)

        // 无偏移:position=15 → first;25 → second
        #expect(LyricsView.currentLineIndex(in: lines, at: 15, offset: 0) == 0)
        #expect(LyricsView.currentLineIndex(in: lines, at: 25, offset: 0) == 1)

        // 正偏移 +2s:line 在 time+offset 激活。position=11 < 10+2=12 → nil(还未到第一行)
        #expect(LyricsView.currentLineIndex(in: lines, at: 11, offset: 2) == nil)
        #expect(LyricsView.currentLineIndex(in: lines, at: 12, offset: 2) == 0)
        #expect(LyricsView.currentLineIndex(in: lines, at: 23, offset: 2) == 1)

        // 负偏移 -2s:第一行在 8s 激活
        #expect(LyricsView.currentLineIndex(in: lines, at: 8, offset: -2) == 0)
    }

    // MARK: - 逐词活跃索引

    @Test("currentWordIndex 取当前行内最近一词 start+offset<=position")
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

    // MARK: - 手动偏移持久化 + 可观察

    @Test("setOffset 持久化到 Track.lyricsOffsetMs 并更新 manualOffsetMs;0 → 清除存 nil")
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

        // 归零 → 存 nil,可观察归零
        svc.setOffset(trackId: track.id, offsetMs: 0)
        #expect(svc.manualOffsetMs == 0)
        let after = (try ctx.fetch(FetchDescriptor<Track>())).first(where: { $0.id == track.id })!
        #expect(after.lyricsOffsetMs == nil)
    }

    @Test("TrackSnapshot(from:) 携带 lyricsOffsetMs")
    func snapshotFromTrackCarriesOffset() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let track = Track(title: "Carry", artist: "A", durationMs: 100000, youTubeId: "test-video")
        track.lyricsOffsetMs = -150
        ctx.insert(track); try ctx.save()
        let snap = TrackSnapshot(from: track)
        #expect(snap.lyricsOffsetMs == -150)
    }

    // MARK: - 回退链 word→line→plain(既有行为保持)

    @Test("既有 parseLRC 行为保持:多时间标签/元数据跳过/无时间行置末")
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
