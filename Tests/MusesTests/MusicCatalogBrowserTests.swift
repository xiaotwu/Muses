import Foundation
import Testing
@testable import Muses

private actor CatalogBrowserFixture: MusicCatalogProviding {
    var failNext = true
    let session = UUID()
    func page(_ ids: [String], next: Bool) -> MusicCatalogPage {
        .init(items: ids.map { .init(id: $0, kind: .song, title: $0, subtitle: "", artwork: nil, artists: [], releases: [], channels: []) }, filters: [], next: next ? .init(session: session, endpoint: "search", token: "fixture") : nil, fetchedAt: Date(), region: "US")
    }
    func search(_ query: String, kind: MusicCatalogKind?) async throws -> MusicCatalogPage { page([query], next: true) }
    func browse(_ id: String) async throws -> MusicCatalogPage { page([id, id], next: true) }
    func next(_ cursor: MusicCatalogCursor) async throws -> MusicCatalogPage {
        if failNext { failNext = false; throw MusicCatalogError.unavailable }
        return page(["first", "second"], next: false)
    }
    func reset() {}
}

@Suite("Structured catalog browser state") @MainActor
struct MusicCatalogBrowserTests {
    private func settle(_ browser: MusicCatalogBrowser) async {
        for _ in 0..<500 where browser.loading { await Task.yield() }
    }
    @Test func failedPagePreservesRowsAndRetryCursor() async {
        let browser = MusicCatalogBrowser(provider: CatalogBrowserFixture())
        browser.search("first")
        await settle(browser)
        #expect(browser.items.map(\.id) == ["first"])
        browser.more()
        await settle(browser)
        #expect(browser.failed)
        #expect(browser.items.map(\.id) == ["first"])
        #expect(browser.nextCursor != nil)
        browser.retry()
        await settle(browser)
        #expect(!browser.failed)
        #expect(browser.items.map(\.id) == ["first", "second"])
        #expect(browser.nextCursor == nil)
    }
    @Test func newQueryClearsOldSelectionImmediately() async {
        let browser = MusicCatalogBrowser(provider: CatalogBrowserFixture())
        browser.search("first")
        await settle(browser)
        browser.search("second", kind: .album)
        #expect(browser.items.isEmpty)
        await settle(browser)
        #expect(browser.items.map(\.id) == ["second"])
        browser.clear()
        #expect(browser.items.isEmpty)
        #expect(browser.fetchedAt == nil)
        #expect(browser.nextCursor == nil)
    }
    @Test func browseRetainsRepeatedOccurrences() async throws {
        let browser = MusicCatalogBrowser(provider: CatalogBrowserFixture())
        browser.search("first")
        await settle(browser)
        browser.open(.init(id: "browse:album", kind: .album, title: "Album", subtitle: "", artwork: nil, artists: [], releases: [], channels: []))
        await settle(browser)
        #expect(browser.items.map(\.id) == ["browse:album", "browse:album"])
        browser.back()
        await settle(browser)
        #expect(browser.items.map(\.id) == ["first"])
    }
    @Test func detailsForwardAndBranchReset() async {
        let browser = MusicCatalogBrowser(provider: CatalogBrowserFixture())
        browser.search("first")
        let a = MusicCatalogItem(id: "browse:a", kind: .album, title: "A", subtitle: "", artwork: nil, artists: [], releases: [], channels: [])
        let b = MusicCatalogItem(id: "browse:b", kind: .album, title: "B", subtitle: "", artwork: nil, artists: [], releases: [], channels: [])
        browser.open(a)
        browser.open(b)
        browser.back()
        #expect(browser.detail?.id == a.id)
        browser.forward()
        #expect(browser.detail?.id == b.id)
        browser.back()
        browser.back()
        #expect(browser.detail == nil)
        browser.open(a)
        #expect(!browser.canGoForward)
        browser.search("new")
        #expect(!browser.canGoBack)
        #expect(!browser.canGoForward)
        browser.clear()
    }
    @Test func podcastCannotAccidentallyEnterMusicQueue() {
        let item = MusicCatalogItem(id: "video:abcdefghijk", kind: .episode, title: "Episode", subtitle: "", artwork: nil, artists: [], releases: [], channels: [])
        #expect(item.playableEntry == nil)
    }
}
