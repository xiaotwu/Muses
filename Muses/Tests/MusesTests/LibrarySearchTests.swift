import Testing
import Foundation
import SwiftData
@testable import Muses

/// 本地库搜索测试:allTracks(search:) 按 title/artist/albumTitle 过滤。
@MainActor
@Suite("LibrarySearch")
struct LibrarySearchTests {

    private func makeContainer() throws -> ModelContainer {
        try makeModelContainer(inMemory: true)
    }

    private func makeLibrary(container: ModelContainer) -> LibraryService {
        LibraryService(modelContainer: container, metadata: MetadataService(artworkCache: .default))
    }

    @discardableResult
    private func seed(_ container: ModelContainer, title: String, artist: String, album: String?) -> Track {
        let ctx = ModelContext(container)
        let track = Track(source: .local, title: title, artist: artist,
                          albumTitle: album, durationMs: 200000)
        ctx.insert(track)
        try? ctx.save()
        return track
    }

    @Test("空 search 返回全量,按 title 排序")
    func emptySearchReturnsAll() throws {
        let container = try makeContainer()
        let library = makeLibrary(container: container)
        seed(container, title: "Zebra", artist: "A", album: nil)
        seed(container, title: "Apple", artist: "B", album: nil)
        seed(container, title: "Mango", artist: "C", album: nil)

        let all = library.allTracks(search: nil)
        #expect(all.count == 3)
        #expect(all.first?.title == "Apple")  // sorted by title
    }

    @Test("search 按 title/artist/album 过滤")
    func searchFiltersByAllFields() throws {
        let container = try makeContainer()
        let library = makeLibrary(container: container)
        seed(container, title: "Bohemian Rhapsody", artist: "Queen", album: "A Night at the Opera")
        seed(container, title: "Yesterday", artist: "The Beatles", album: "Help!")
        seed(container, title: "Don't Stop Me Now", artist: "Queen", album: "Jazz")

        // By title
        #expect(library.allTracks(search: "Bohemian").count == 1)
        // By artist (case-insensitive)
        #expect(library.allTracks(search: "queen").count == 2)
        // By album
        #expect(library.allTracks(search: "Jazz").count == 1)
        // No match
        #expect(library.allTracks(search: "xyzabc").isEmpty)
    }
}