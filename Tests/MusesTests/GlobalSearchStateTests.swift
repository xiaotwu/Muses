import Foundation
import Testing
@testable import Muses

@Suite("Global search request state", .serialized)
@MainActor
struct GlobalSearchStateTests {
    private func library() throws -> LibraryService {
        LibraryService(modelContainer: try makeModelContainer(inMemory: true))
    }

    @Test("Changing query immediately removes stale selectable results")
    func queryClearsResults() async throws {
        let service = GlobalSearchService(library: try library(), debounceMs: 60_000,
                                          remoteSearch: { _, _ in [.init(id: "abcdefghijk", title: "Old")] })
        service.scope = .youtube
        await service.performSearch(query: "old")
        #expect(service.youtubeResults.count == 1)
        service.query = "new"
        #expect(service.youtubeResults.isEmpty)
        #expect(service.isSearchingYouTube)
        service.cancelSearch()
    }

    @Test("Cancelled noncooperative response cannot repopulate results")
    func cancellationRejectsResponse() async throws {
        var continuation: CheckedContinuation<[YTDlpBridge.YTDlpPlaylistEntry], Never>?
        let service = GlobalSearchService(library: try library(), remoteSearch: { _, _ in
            await withCheckedContinuation { continuation = $0 }
        })
        service.scope = .youtube
        let request = Task { await service.performSearch(query: "old") }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        service.cancelSearch()
        pending.resume(returning: [.init(id: "abcdefghijk", title: "Old")])
        await request.value
        #expect(service.youtubeResults.isEmpty)
        #expect(service.wasCancelled)
        #expect(!service.isSearchingYouTube)
    }

    @Test("Loading more merges changing ranked prefixes without duplicates or losing prior rows")
    func loadMoreResults() async throws {
        let service = GlobalSearchService(library: try library(), remoteSearch: { _, limit in
            (0..<limit).map { index in
                .init(id: String(format: "%011d", index + (limit > 20 ? 5 : 0)), title: "Song")
            }
        })
        service.scope = .youtube
        await service.performSearch(query: "song")
        #expect(service.youtubeResults.count == 20)
        #expect(service.canLoadMore)
        service.loadMore()
        for _ in 0..<100 where service.isSearchingYouTube { await Task.yield() }
        #expect(service.youtubeResults.count == 45)
        #expect(service.youtubeResults.first?.id == "00000000000")
        #expect(Set(service.youtubeResults.map(\.id)).count == 45)
        service.cancelSearch()
    }

    @Test("A queued load-more task cannot revive a query after input changes")
    func supersededLoadMore() async throws {
        let service = GlobalSearchService(library: try library(), debounceMs: 60_000, remoteSearch: { _, limit in
            (0..<limit).map { .init(id: String(format: "%011d", $0), title: "Old") }
        })
        service.scope = .youtube
        await service.performSearch(query: "old")
        service.loadMore()
        service.query = "new"
        for _ in 0..<20 { await Task.yield() }
        #expect(service.youtubeResults.isEmpty)
        #expect(service.query == "new")
        service.cancelSearch()
    }

    @Test("Unavailable remote search is distinguished from an empty result")
    func unavailableSearch() async throws {
        let service = GlobalSearchService(library: try library())
        service.scope = .youtube
        await service.performSearch(query: "song")
        #expect(service.youtubeError != nil)
        #expect(!service.isSearchingYouTube)
        service.scope = .library
        await service.performSearch(query: "song")
        #expect(service.youtubeError == nil)
        #expect(!service.wasCancelled)
    }
}
