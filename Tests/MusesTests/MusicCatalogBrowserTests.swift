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

private final class CatalogLocaleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LocaleScopedMusicCatalogProvider.Scope
    init(_ value: LocaleScopedMusicCatalogProvider.Scope) { self.value = value }
    func get() -> LocaleScopedMusicCatalogProvider.Scope { lock.withLock { value } }
    func set(_ value: LocaleScopedMusicCatalogProvider.Scope) {
        lock.withLock { self.value = value }
    }
}

private actor LocaleCatalogFixture: MusicCatalogProviding {
    let scope: LocaleScopedMusicCatalogProvider.Scope
    let session = UUID()
    init(scope: LocaleScopedMusicCatalogProvider.Scope) { self.scope = scope }
    func search(_ query: String, kind: MusicCatalogKind?) async throws
        -> MusicCatalogPage { page(query) }
    func browse(_ id: String) async throws -> MusicCatalogPage { page(id) }
    func next(_ cursor: MusicCatalogCursor) async throws -> MusicCatalogPage {
        guard cursor.session == session else { throw MusicCatalogError.expiredCursor }
        return page("next")
    }
    func reset() {}
    private func page(_ title: String) -> MusicCatalogPage {
        .init(
            items: [.init(id: "video:abcdefghijk", kind: .song,
                          title: title, subtitle: "", artwork: nil,
                          artists: [], releases: [], channels: [])],
            filters: [],
            next: .init(session: session, endpoint: "search", token: "token",
                        region: scope.region, language: scope.language),
            fetchedAt: Date(), region: scope.region, language: scope.language)
    }
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
    @Test func podcastEpisodeUsesUnifiedYouTubePlaybackPath() {
        let item = MusicCatalogItem(id: "video:abcdefghijk", kind: .episode, title: "Episode", subtitle: "", artwork: nil, artists: [], releases: [], channels: [])
        #expect(item.playableEntry?.id == "abcdefghijk")
    }

    @Test("app-language changes rotate provider scope and invalidate cursors")
    func localeChangesInvalidateCursor() async throws {
        let initial = LocaleScopedMusicCatalogProvider.Scope(
            region: "US", language: "en")
        let box = CatalogLocaleBox(initial)
        let provider = LocaleScopedMusicCatalogProvider(
            scopeProvider: { box.get() },
            factory: { LocaleCatalogFixture(scope: $0) })
        let english = try await provider.search("English", kind: nil)
        let oldCursor = try #require(english.next)
        #expect(english.language == "en")

        box.set(.init(region: "TW", language: "zh-Hant"))
        await #expect(throws: MusicCatalogError.self) {
            try await provider.next(oldCursor)
        }
        let traditional = try await provider.search("繁體", kind: nil)
        #expect(traditional.region == "TW")
        #expect(traditional.language == "zh-Hant")
        #expect(traditional.next?.language == "zh-Hant")
    }
}
