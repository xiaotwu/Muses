import Testing
import Foundation
@testable import Muses

@MainActor
@Suite("LyricsService")
struct LyricsServiceTests {

    // MARK: - 1. LRCLIB fetch via stub URLProtocol

    @Test("LRCLIB fetch returns synced lyrics via stub URLProtocol")
    func lrclibFetchReturnsSyncedLyrics() async throws {
        let cannedJSON = """
        {
          "plainLyrics": "hello world",
          "syncedLyrics": "[00:01.00] hello\\n[00:03.50] world"
        }
        """
        StubURLProtocol.reset()
        let stub = StubURLProtocol()
        stub.respond(forHostEndingWith: "lrclib.net") { _ in
            StubResponse(statusCode: 200, body: Data(cannedJSON.utf8))
        }

        let session = URLSession(configuration: StubURLProtocol.makeConfig(stub))
        let service = LyricsService(session: session)

        let track = TrackSnapshot(
            id: UUID(),
            title: "Test",
            artist: "Artist",
            albumTitle: nil,
            durationSeconds: 200,
            filePath: nil,
            youTubeId: nil,
            artworkHash: nil,
            artworkUrl: nil,
            sampleRate: nil,
            bitDepth: nil,
            codec: nil,
            isLossless: false
        )

        // 强制使用 lrclib 来源(且 filePath 为 nil,本地回退不会命中)。
        let original = UserDefaults.standard.string(forKey: PrefKey.lyricsSource)
        UserDefaults.standard.set("lrclib", forKey: PrefKey.lyricsSource)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: PrefKey.lyricsSource)
            } else {
                UserDefaults.standard.removeObject(forKey: PrefKey.lyricsSource)
            }
        }

        let result = try #require(await service.fetch(track: track))
        #expect(result.source == LyricsSource.lrclib)
        #expect(result.syncedLyrics != nil)
        #expect(result.syncedLyrics?.contains("[00:01.00] hello") == true)
        #expect(result.plainLyrics == "hello world")
    }

    // MARK: - 2. parseLRC parses multiple timestamps

    @Test("parseLRC parses multiple timestamps and sorts by time")
    func parseLRCMultipleTimestamps() {
        let lrc = """
        [01:23.45][02:45.67] shared lyric
        [00:05.00] first line
        plain text no time
        """
        let lines = LyricsService.parseLRC(lrc)
        // 3 timestamped lines + 1 untimed line = 4 total.
        #expect(lines.count == 4)

        // Sorted by time: 5.0, 83.45, 165.67, then nil at end.
        #expect(lines[0].time == 5.0)
        #expect(lines[0].text == "first line")
        #expect(lines[1].time == 83.45)
        #expect(lines[1].text == "shared lyric")
        #expect(lines[2].time == 165.67)
        #expect(lines[2].text == "shared lyric")
        #expect(lines[3].time == nil)
        #expect(lines[3].text == "plain text no time")

        // 每个 LyricLine 应有唯一 UUID。
        let ids = Set(lines.map { $0.id })
        #expect(ids.count == lines.count)
    }

    // MARK: - 3. parseLRC skips metadata tags

    @Test("parseLRC skips LRC metadata tags")
    func parseLRCSkipsMetadata() {
        let lrc = """
        [ti:Song Title]
        [ar:Artist]
        [00:10.00] actual lyric
        """
        let lines = LyricsService.parseLRC(lrc)
        #expect(lines.count == 1)
        #expect(lines[0].time == 10.0)
        #expect(lines[0].text == "actual lyric")
    }

    // MARK: - 4. local .lrc file lookup

    @Test("local .lrc file lookup returns synced lyrics")
    func localLrcFileLookup() async throws {
        // 在临时目录创建 test.wav(空)与同名 test.lrc。
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "muses-lyrics-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wavURL = tempDir.appending(path: "test.wav")
        try Data().write(to: wavURL)
        let lrcURL = tempDir.appending(path: "test.lrc")
        let lrcContent = "[00:01.00] hello"
        try Data(lrcContent.utf8).write(to: lrcURL)

        // 设置来源为 local。
        let original = UserDefaults.standard.string(forKey: PrefKey.lyricsSource)
        UserDefaults.standard.set("local", forKey: PrefKey.lyricsSource)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: PrefKey.lyricsSource)
            } else {
                UserDefaults.standard.removeObject(forKey: PrefKey.lyricsSource)
            }
        }

        // LRCLIB 不应被命中:注册 404 stub 以防意外网络调用。
        StubURLProtocol.reset()
        let stub = StubURLProtocol()
        stub.respond(forHostEndingWith: "lrclib.net") { _ in
            StubResponse(statusCode: 404, body: Data())
        }
        let session = URLSession(configuration: StubURLProtocol.makeConfig(stub))

        let service = LyricsService(session: session)
        let track = TrackSnapshot(
            id: UUID(),
            title: "Test",
            artist: "Artist",
            albumTitle: nil,
            durationSeconds: 200,
            filePath: wavURL.path,
            youTubeId: nil,
            artworkHash: nil,
            artworkUrl: nil,
            sampleRate: nil,
            bitDepth: nil,
            codec: nil,
            isLossless: false
        )

        let result = try #require(await service.fetch(track: track))
        #expect(result.source == LyricsSource.local)
        #expect(result.syncedLyrics != nil)
        #expect(result.syncedLyrics?.contains("[00:01.00] hello") == true)
    }
}