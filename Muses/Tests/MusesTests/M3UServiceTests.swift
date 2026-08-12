import Testing
import Foundation
import SwiftData
@testable import Muses

/// M3U 解析与导出测试。
@MainActor
@Suite("M3UService")
struct M3UServiceTests {

    private func makeContainer() throws -> ModelContainer {
        try makeModelContainer(inMemory: true)
    }

    // MARK: - 解析

    @Test("parse 跳过注释和空行,收集文件路径")
    func parseExtractsPaths() throws {
        let content = """
        #EXTM3U
        #EXTINF:200,Artist - Song A
        /music/song-a.flac

        #EXTINF:180,Artist - Song B
        /music/song-b.flac
        """
        let paths = M3UService.parse(content: content)
        #expect(paths == ["/music/song-a.flac", "/music/song-b.flac"])
    }

    @Test("parse 从文件 URL 读取")
    func parseFromFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "m3u-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let m3u = dir.appending(path: "test.m3u")
        let content = """
        #EXTM3U
        #EXTINF:120,Artist - Song
        /music/song.mp3
        """
        try content.write(to: m3u, atomically: true, encoding: .utf8)

        let paths = try M3UService.parse(url: m3u)
        #expect(paths == ["/music/song.mp3"])
    }

    // MARK: - 导出

    @Test("export 生成正确的 M3U 格式")
    func exportFormat() {
        let entries: [(filePath: String, title: String, durationSeconds: Double)] = [
            (filePath: "/music/a.flac", title: "Artist - A", durationSeconds: 200.7),
            (filePath: "/music/b.flac", title: "Artist - B", durationSeconds: 180.0),
        ]
        let content = M3UService.export(entries: entries)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "#EXTM3U")
        #expect(lines[1] == "#EXTINF:201,Artist - A")
        #expect(lines[2] == "/music/a.flac")
        #expect(lines[3] == "#EXTINF:180,Artist - B")
        #expect(lines[4] == "/music/b.flac")
    }

    @Test("export relativeTo 将同目录路径转为相对路径")
    func exportRelativePath() {
        let entries: [(filePath: String, title: String, durationSeconds: Double)] = [
            (filePath: "/music/album/song.flac", title: "Artist - Song", durationSeconds: 100),
            (filePath: "/other/song2.flac", title: "Artist - Song2", durationSeconds: 100),
        ]
        let base = URL(fileURLWithPath: "/music/album")
        let content = M3UService.export(entries: entries, relativeTo: base)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[2] == "song.flac", "同目录 → 相对路径")
        #expect(lines[4] == "/other/song2.flac", "不同目录 → 保留绝对路径")
    }

    // MARK: - PlaylistService 集成

    @Test("importM3U 按 filePath 匹配并添加曲目")
    func importM3UMatchesTracks() throws {
        let container = try makeContainer()
        let service = PlaylistService(modelContainer: container)

        // 构造 2 个 Track,带 filePath
        let ctx = ModelContext(container)
        let t1 = Track(source: .local, title: "A", artist: "Art", durationMs: 200000)
        t1.filePath = "/music/a.flac"
        let t2 = Track(source: .local, title: "B", artist: "Art", durationMs: 180000)
        t2.filePath = "/music/b.flac"
        ctx.insert(t1)
        ctx.insert(t2)
        try ctx.save()

        // 写 M3U 文件
        let dir = FileManager.default.temporaryDirectory.appending(path: "m3u-imp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let m3u = dir.appending(path: "test.m3u")
        let content = """
        #EXTM3U
        #EXTINF:200,Art - A
        /music/a.flac
        #EXTINF:180,Art - B
        /music/b.flac
        /music/not-in-library.flac
        """
        try content.write(to: m3u, atomically: true, encoding: .utf8)

        let playlist = service.create(name: "Imported")
        let added = service.importM3U(playlist, from: m3u)
        #expect(added == 2, "应添加 2 首(第 3 首无匹配)")

        // 验证 playlist 内有 2 个 item
        let verifyCtx = ModelContext(container)
        let p = try #require(verifyCtx.fetch(FetchDescriptor<Playlist>()).first)
        let items = (p.items ?? []).sorted { $0.order < $1.order }
        #expect(items.count == 2)
        #expect(items[0].track?.title == "A")
        #expect(items[1].track?.title == "B")
    }

    @Test("exportM3U 导出歌单曲目为 M3U 文件")
    func exportM3UWritesFile() throws {
        let container = try makeContainer()
        let service = PlaylistService(modelContainer: container)

        let ctx = ModelContext(container)
        let t1 = Track(source: .local, title: "Song A", artist: "Artist", durationMs: 200000)
        t1.filePath = "/music/song-a.flac"
        let t2 = Track(source: .local, title: "Song B", artist: "Artist", durationMs: 180000)
        t2.filePath = "/music/song-b.flac"
        ctx.insert(t1)
        ctx.insert(t2)
        try ctx.save()

        let playlist = service.create(name: "Export Test")
        service.addTrack(playlist, track: t1)
        service.addTrack(playlist, track: t2)

        let outDir = FileManager.default.temporaryDirectory.appending(path: "m3u-exp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }
        let outFile = outDir.appending(path: "exported.m3u")

        service.exportM3U(playlist, to: outFile)

        let content = try String(contentsOf: outFile, encoding: .utf8)
        let paths = M3UService.parse(content: content)
        #expect(paths == ["/music/song-a.flac", "/music/song-b.flac"])
        #expect(content.hasPrefix("#EXTM3U"))
        #expect(content.contains("#EXTINF:200,Artist - Song A"))
        #expect(content.contains("#EXTINF:180,Artist - Song B"))
    }
}