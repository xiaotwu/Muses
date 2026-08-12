import Testing
import Foundation
import SwiftData
@testable import Muses

/// 艺术家浏览(派生方案)测试:allArtists 去重排序,albums(byArtist:) 过滤。
@MainActor
@Suite("ArtistBrowse")
struct ArtistBrowseTests {

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
        // 每张专辑至少一首歌,确保 allArtists 数据来源完整
        let track = Track(source: .local, title: "\(title) — Track 1", artist: artist,
                          albumTitle: title, albumArtist: artist, durationMs: 200000)
        track.album = album
        ctx.insert(track)
        try? ctx.save()
        return album
    }

    @Test("allArtists 返回去重 + 排序")
    func allArtistsDistinctSorted() throws {
        let container = try makeContainer()
        let library = makeLibrary(container: container)
        seedAlbum(container, title: "A Night at the Opera", artist: "Queen")
        seedAlbum(container, title: "Jazz", artist: "Queen")
        seedAlbum(container, title: "Help!", artist: "The Beatles")
        seedAlbum(container, title: "Abbey Road", artist: "The Beatles")

        let artists = library.allArtists()
        #expect(artists == ["Queen", "The Beatles"])  // 去重 + 按字母排序
    }

    @Test("albums(byArtist:) 只返回匹配的 Album")
    func albumsByArtistFilters() throws {
        let container = try makeContainer()
        let library = makeLibrary(container: container)
        seedAlbum(container, title: "A Night at the Opera", artist: "Queen")
        seedAlbum(container, title: "Jazz", artist: "Queen")
        seedAlbum(container, title: "Help!", artist: "The Beatles")

        let queen = library.albums(byArtist: "Queen")
        #expect(queen.count == 2)
        #expect(queen.allSatisfy { $0.albumArtist == "Queen" })
        #expect(queen.first?.title == "A Night at the Opera")  // sorted by title

        let beatles = library.albums(byArtist: "The Beatles")
        #expect(beatles.count == 1)

        #expect(library.albums(byArtist: "Nobody").isEmpty)
    }
}