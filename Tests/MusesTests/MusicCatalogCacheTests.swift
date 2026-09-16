import Foundation
import Testing
@testable import Muses

private actor CachedCatalogFixture: MusicCatalogProviding {
    var failing = false
    var calls = 0
    func fail() { failing = true }
    func reset() {}
    func search(_ query: String, kind: MusicCatalogKind?) async throws -> MusicCatalogPage {
        calls += 1
        if failing { throw MusicCatalogError.unavailable }
        return .init(items: [.init(id: "video:abcdefghijk", kind: .song, title: "Source title", subtitle: "", artwork: nil, artists: [], releases: [], channels: [])], filters: [.init(kind: .song, params: "secret-filter")], next: .init(session: UUID(), endpoint: "search", token: "secret-cursor"), fetchedAt: Date(timeIntervalSince1970: 1_700_000_000), region: "US")
    }
    func browse(_ id: String) async throws -> MusicCatalogPage { try await search(id, kind: nil) }
    func next(_ cursor: MusicCatalogCursor) async throws -> MusicCatalogPage { throw MusicCatalogError.unavailable }
}

@Suite("Anonymous catalog display cache")
struct MusicCatalogCacheTests {
    @Test func staleRecoveryHasNoCredentialsOrCursorAndRetainsDate() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = CachedCatalogFixture()
        let provider = CachedMusicCatalogProvider(upstream: upstream, directory: directory)
        let fresh = try await provider.search("private-query", kind: .song)
        #expect(!fresh.isStale)
        #expect(fresh.next != nil)
        await upstream.fail()
        let reloaded = CachedMusicCatalogProvider(upstream: upstream, directory: directory)
        let saved = try await reloaded.search("private-query", kind: .song)
        #expect(saved.isStale && saved.refreshFailed)
        #expect(saved.fetchedAt == fresh.fetchedAt)
        #expect(saved.items == fresh.items)
        #expect(saved.next == nil && saved.filters.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let file = try #require(files.first)
        let contents = try String(contentsOf: file, encoding: .utf8)
        for excluded in ["secret-filter", "secret-cursor", "private-query", "continuation", "visitorData"] { #expect(!contents.contains(excluded)) }
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        await #expect(throws: MusicCatalogError.self) { try await reloaded.search("different-query", kind: .song) }
        await #expect(throws: MusicCatalogError.self) { try await reloaded.search("private-query", kind: .album) }
        let otherRegion = CachedMusicCatalogProvider(upstream: upstream, directory: directory, region: "GB")
        await #expect(throws: MusicCatalogError.self) { try await otherRegion.search("private-query", kind: .song) }
        await #expect(throws: MusicCatalogError.self) { try await reloaded.next(try #require(fresh.next)) }
    }

    @Test func damagedCacheDoesNotTurnFailureIntoEmptySuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = CachedCatalogFixture()
        let provider = CachedMusicCatalogProvider(upstream: upstream, directory: directory)
        _ = try await provider.search("query", kind: nil)
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("corrupt".utf8).write(to: file)
        await upstream.fail()
        await #expect(throws: MusicCatalogError.self) { try await provider.search("query", kind: nil) }
    }
}
