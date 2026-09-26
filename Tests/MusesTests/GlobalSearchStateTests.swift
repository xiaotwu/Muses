import Foundation
import Testing
@testable import Muses

@Suite("Global search request state", .serialized)
@MainActor
struct GlobalSearchStateTests {
    private func library() throws -> LibraryService {
        LibraryService(modelContainer: try makeModelContainer(inMemory: true))
    }

    @Test("Online scopes delegate empty and failure states to their own sources")
    func sourceScopedEmptyStates() async throws {
        let service = GlobalSearchService(library: try library(), debounceMs: 60_000)
        for scope in [GlobalSearchScope.all, .youtube] {
            service.scope = scope
            #expect(!service.showsLibraryEmptyState)
            await service.performSearch(query: "missing")
            #expect(service.youtubeError != nil)
            #expect(service.additionalResultsStatus != nil)
            #expect(!service.showsLibraryEmptyState)
            service.cancelSearch()
            #expect(!service.showsLibraryEmptyState)
        }
        service.scope = .library
        await service.performSearch(query: "missing")
        #expect(service.showsLibraryEmptyState)
        #expect(service.additionalResultsStatus == nil)
        service.reset()
    }

    @Test("Supplemental retry preserves successful and stale structured results")
    func retryPreservesCatalog() async throws {
        for stale in [false, true] {
            let browser = MusicCatalogBrowser(provider: SearchStatusCatalogFixture(stale: stale))
            var attempts = 0
            let service = GlobalSearchService(library: try library(), debounceMs: 60_000,
                                              musicCatalog: browser, remoteSearch: { _, _ in
                attempts += 1
                if attempts == 1 { throw MusicCatalogError.unavailable }
                return []
            })
            service.query = "song"
            await service.performSearch(query: "song")
            browser.search("song")
            for _ in 0..<500 where browser.loading { await Task.yield() }
            #expect(browser.items.count == 1)
            #expect(browser.isStale == stale)
            #expect(!service.showsLibraryEmptyState)
            service.retrySearch()
            #expect(browser.items.count == 1)
            for _ in 0..<500 where attempts < 2 { await Task.yield() }
            #expect(attempts == 2)
            #expect(service.youtubeError == nil)
            #expect(browser.items.count == 1)
            #expect(browser.isStale == stale)
            service.reset()
        }
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

private actor SearchStatusCatalogFixture: MusicCatalogProviding {
    let stale: Bool
    init(stale: Bool) { self.stale = stale }
    func search(_ query: String, kind: MusicCatalogKind?) async throws -> MusicCatalogPage {
        .init(items: [.init(id: "video:abcdefghijk", kind: .song, title: "Song", subtitle: "",
                           artwork: nil, artists: [], releases: [], channels: [])],
              filters: [], next: nil, fetchedAt: Date(), region: "US",
              isStale: stale, refreshFailed: stale)
    }
    func browse(_ id: String) async throws -> MusicCatalogPage { try await search(id, kind: nil) }
    func next(_ cursor: MusicCatalogCursor) async throws -> MusicCatalogPage { throw MusicCatalogError.unavailable }
    func reset() {}
}
