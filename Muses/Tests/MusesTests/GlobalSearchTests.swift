import Testing
import Foundation
import SwiftData
@testable import Muses

@MainActor
@Suite("GlobalSearch")
struct GlobalSearchTests {

    private func makeContainer() throws -> ModelContainer {
        try makeModelContainer(inMemory: true)
    }

    private func makeLibrary(container: ModelContainer) -> LibraryService {
        LibraryService(modelContainer: container, metadata: MetadataService(artworkCache: .default))
    }

    @discardableResult
    private func seedAlbum(_ container: ModelContainer, title: String, artist: String) -> Album {
        let ctx = ModelContext(container)
        let album = Album(title: title, albumArtist: artist)
        ctx.insert(album)
        let track = Track(source: .local, title: "\(title) — Track 1", artist: artist,
                          albumTitle: title, albumArtist: artist, durationMs: 200000)
        track.album = album
        ctx.insert(track)
        try? ctx.save()
        return album
    }

    @Test("本地搜索返回歌曲/专辑/艺术家结果")
    func localSearchReturnsResults() async throws {
        let container = try makeContainer()
        let library = makeLibrary(container: container)
        seedAlbum(container, title: "Discovery", artist: "Daft Punk")
        seedAlbum(container, title: "Random Access Memories", artist: "Daft Punk")
        seedAlbum(container, title: "Abbey Road", artist: "The Beatles")
        library.backfillArtists()

        let search = GlobalSearchService(library: library, youTubeSearch: nil, debounceMs: 10)

        // 直接驱动搜索,不依赖 debounce 的墙钟调度(消除全量跑测时的 timing flake)。
        search.query = "Daft"
        await search.performSearch(query: "Daft")

        #expect(search.trackResults.count == 2)  // 2 tracks by Daft Punk
        #expect(search.albumResults.count == 2)  // 2 albums
        #expect(search.artistResults.count == 1) // 1 artist
        #expect(search.artistResults.first?.name == "Daft Punk")
    }

    @Test("空查询清除结果")
    func emptyQueryClearsResults() async throws {
        let container = try makeContainer()
        let library = makeLibrary(container: container)
        seedAlbum(container, title: "Discovery", artist: "Daft Punk")
        library.backfillArtists()

        let search = GlobalSearchService(library: library, youTubeSearch: nil, debounceMs: 10)

        search.query = "Daft"
        await search.performSearch(query: "Daft")
        #expect(!search.trackResults.isEmpty)

        // 空查询在 `scheduleSearch` 同步清空结果(didSet 即时执行),无需 debounce。
        search.query = ""
        #expect(search.trackResults.isEmpty)
        #expect(search.albumResults.isEmpty)
        #expect(search.artistResults.isEmpty)
        #expect(search.youtubeResults.isEmpty)
    }

    @Test("reset 清除所有状态")
    func resetClearsAll() async throws {
        let container = try makeContainer()
        let library = makeLibrary(container: container)
        seedAlbum(container, title: "Discovery", artist: "Daft Punk")
        library.backfillArtists()

        let search = GlobalSearchService(library: library, youTubeSearch: nil, debounceMs: 10)
        search.query = "Daft"
        await search.performSearch(query: "Daft")
        #expect(!search.trackResults.isEmpty)

        // reset() 同步清空,不涉及 debounce。
        search.reset()
        #expect(search.query.isEmpty)
        #expect(search.trackResults.isEmpty)
        #expect(search.albumResults.isEmpty)
        #expect(search.artistResults.isEmpty)
    }
}