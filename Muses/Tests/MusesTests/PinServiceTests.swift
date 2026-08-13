import Testing
import Foundation
import SwiftData
@testable import Muses

/// 钉选功能测试(Album + Playlist)。
@MainActor
@Suite("PinService")
struct PinServiceTests {

    private func makeContainer() throws -> ModelContainer {
        try makeModelContainer(inMemory: true)
    }

    @Test("togglePin 切换专辑钉选状态")
    func togglePinAlbum() async throws {
        let container = try makeContainer()
        let library = LibraryService(modelContainer: container, metadata: MetadataService(
            artworkCache: ArtworkCache(directory: FileManager.default.temporaryDirectory
                .appending(path: "muses-pin-test"))))

        let dir = FileManager.default.temporaryDirectory.appending(path: "muses-pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try makeSilentWav(at: dir.appending(path: "tone.wav"), seconds: 1)
        try await library.addScanRoot(dir, watch: false)

        let album = try #require(library.allAlbums().first)
        #expect(album.pinned == false, "初始未钉选")
        #expect(library.pinnedAlbums().count == 0)

        library.togglePin(album)
        #expect(library.pinnedAlbums().count == 1, "钉选后应有 1 个")
        #expect(library.isPinned(album) == true)

        library.togglePin(album)
        #expect(library.pinnedAlbums().count == 0, "取消钉选后应为 0")
    }

    @Test("togglePin 切换歌单钉选状态")
    func togglePinPlaylist() throws {
        let container = try makeContainer()
        let service = PlaylistService(modelContainer: container)

        let playlist = service.create(name: "Test Playlist")
        #expect(playlist.pinned == false, "初始未钉选")
        #expect(service.pinnedPlaylists().count == 0)

        service.togglePin(playlist)
        #expect(service.pinnedPlaylists().count == 1, "钉选后应有 1 个")

        service.togglePin(playlist)
        #expect(service.pinnedPlaylists().count == 0, "取消钉选后应为 0")
    }

    @Test("pinnedAlbums 只返回已钉选专辑")
    func pinnedAlbumsFilters() async throws {
        let container = try makeContainer()
        let library = LibraryService(modelContainer: container, metadata: MetadataService(
            artworkCache: ArtworkCache(directory: FileManager.default.temporaryDirectory
                .appending(path: "muses-pin-filter-test"))))

        let dir = FileManager.default.temporaryDirectory.appending(path: "muses-pin-f-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try makeSilentWav(at: dir.appending(path: "a.wav"), seconds: 1)
        try makeSilentWav(at: dir.appending(path: "b.wav"), seconds: 1)
        try await library.addScanRoot(dir, watch: false)

        let albums = library.allAlbums()
        #expect(albums.count >= 1)

        // 钉选第一个专辑
        if let first = albums.first {
            library.togglePin(first)
        }
        #expect(library.pinnedAlbums().count == 1)
    }
}