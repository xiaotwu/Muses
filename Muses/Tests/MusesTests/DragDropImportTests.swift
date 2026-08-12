import Testing
import Foundation
import SwiftData
@testable import Muses

/// 拖拽导入测试:importURLs 处理文件夹和文件,创建 Track。
@MainActor
@Suite("DragDropImport")
struct DragDropImportTests {

    @Test("importURLs 导入单个音频文件创建 Track")
    func importSingleFile() async throws {
        let container = try makeModelContainer(inMemory: true)
        let cacheDir = FileManager.default.temporaryDirectory.appending(path: "muses-dd-\(UUID().uuidString)")
        let svc = LibraryService(modelContainer: container, metadata: MetadataService(artworkCache: ArtworkCache(directory: cacheDir)))

        let dir = FileManager.default.temporaryDirectory.appending(path: "muses-dd-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appending(path: "dropped.wav")
        try makeSilentWav(at: wav, seconds: 1)

        await svc.importURLs([wav])

        let tracks = svc.allTracks()
        #expect(tracks.count == 1)
        #expect(tracks.first?.filePath?.hasSuffix("dropped.wav") == true)
    }

    @Test("importURLs 导入文件夹递归扫描")
    func importDirectory() async throws {
        let container = try makeModelContainer(inMemory: true)
        let cacheDir = FileManager.default.temporaryDirectory.appending(path: "muses-dd2-\(UUID().uuidString)")
        let svc = LibraryService(modelContainer: container, metadata: MetadataService(artworkCache: ArtworkCache(directory: cacheDir)))

        let dir = FileManager.default.temporaryDirectory.appending(path: "muses-dd-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try makeSilentWav(at: dir.appending(path: "a.wav"), seconds: 1)
        try makeSilentWav(at: dir.appending(path: "b.wav"), seconds: 1)

        await svc.importURLs([dir])

        let tracks = svc.allTracks()
        #expect(tracks.count == 2)
    }

    @Test("importURLs 忽略非音频文件")
    func ignoresNonAudio() async throws {
        let container = try makeModelContainer(inMemory: true)
        let cacheDir = FileManager.default.temporaryDirectory.appending(path: "muses-dd3-\(UUID().uuidString)")
        let svc = LibraryService(modelContainer: container, metadata: MetadataService(artworkCache: ArtworkCache(directory: cacheDir)))

        let dir = FileManager.default.temporaryDirectory.appending(path: "muses-dd-none-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not audio".utf8).write(to: dir.appending(path: "readme.txt"))

        await svc.importURLs([dir])

        #expect(svc.allTracks().isEmpty)
    }
}