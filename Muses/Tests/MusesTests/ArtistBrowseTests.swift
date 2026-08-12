import Testing
import Foundation
import SwiftData
@testable import Muses

/// 艺术家浏览测试:backfillArtists 创建 + 链接,allArtists 返回 [Artist],
/// albums(byArtist:)/tracks(byArtist:) 关系遍历。
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

    @Test("backfillArtists 创建 Artist 并链接 albums/tracks")
    func backfillCreatesAndLinks() throws {
        let container = try makeContainer()
        let library = makeLibrary(container: container)
        seedAlbum(container, title: "A Night at the Opera", artist: "Queen")
        seedAlbum(container, title: "Jazz", artist: "Queen")
        seedAlbum(container, title: "Help!", artist: "The Beatles")

        // backfill 之前没有 Artist 实体
        #expect(library.allArtists().isEmpty)

        library.backfillArtists()

        let artists = library.allArtists()
        #expect(artists.count == 2)  // Queen + The Beatles(去重)
        #expect(artists.map(\.name) == ["Queen", "The Beatles"])  // 按名排序

        // 验证关系链接:Queen 的 albums 包含 2 张,traces 包含 2 首
        let queen = artists.first { $0.name == "Queen" }!
        #expect(library.albums(byArtist: queen).count == 2)
        #expect(library.tracks(byArtist: queen).count == 2)
    }

    @Test("allArtists 返回去重 + 排序的 [Artist]")
    func allArtistsDistinctSorted() throws {
        let container = try makeContainer()
        let library = makeLibrary(container: container)
        seedAlbum(container, title: "A Night at the Opera", artist: "Queen")
        seedAlbum(container, title: "Jazz", artist: "Queen")
        seedAlbum(container, title: "Help!", artist: "The Beatles")
        seedAlbum(container, title: "Abbey Road", artist: "The Beatles")

        library.backfillArtists()

        let artists = library.allArtists()
        #expect(artists.count == 2)  // 去重
        #expect(artists.map(\.name) == ["Queen", "The Beatles"])  // 按字母排序
    }

    @Test("albums(byArtist:) 关系遍历只返回匹配的 Album")
    func albumsByArtistRelationship() throws {
        let container = try makeContainer()
        let library = makeLibrary(container: container)
        seedAlbum(container, title: "A Night at the Opera", artist: "Queen")
        seedAlbum(container, title: "Jazz", artist: "Queen")
        seedAlbum(container, title: "Help!", artist: "The Beatles")

        library.backfillArtists()

        let queen = library.allArtists().first { $0.name == "Queen" }!
        let queenAlbums = library.albums(byArtist: queen)
        #expect(queenAlbums.count == 2)
        #expect(queenAlbums.allSatisfy { $0.albumArtist == "Queen" })
        #expect(queenAlbums.first?.title == "A Night at the Opera")  // sorted by title

        let beatles = library.allArtists().first { $0.name == "The Beatles" }!
        #expect(library.albums(byArtist: beatles).count == 1)
    }

    @Test("backfillArtists 幂等 — 重复调用不创建重复 Artist")
    func backfillIdempotent() throws {
        let container = try makeContainer()
        let library = makeLibrary(container: container)
        seedAlbum(container, title: "Jazz", artist: "Queen")

        library.backfillArtists()
        library.backfillArtists()  // 重复调用

        #expect(library.allArtists().count == 1)  // 不重复
    }
}