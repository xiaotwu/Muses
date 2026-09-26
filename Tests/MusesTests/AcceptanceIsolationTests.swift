import Foundation
import Testing
@testable import Muses

@Suite("Acceptance isolation")
struct AcceptanceIsolationTests {
    @Test("Acceptance disk roots persist across launches without redirecting production")
    func diskNamespaces() {
        let base = URL(fileURLWithPath: "/tmp/muses-path-test", isDirectory: true)
        let production = MusesDataPaths.dataDirectory(bundleID: "com.muses.app")
        let isolated = MusesDataPaths.dataDirectory(bundleID: "com.muses.acceptance.batch23")
        #expect(production.path == URL.homeDirectory.appending(path: ".muses/data").path)
        #expect(isolated.path == URL.homeDirectory.appending(path:
            ".muses/acceptance/com.muses.acceptance.batch23/data").path)
        #expect(production != isolated)
        #expect(MusesDataPaths.legacyDirectory(in: base, bundleID: "com.muses.app").path
                == "/tmp/muses-path-test/Muses")
        #expect(MusesDataPaths.legacyDirectory(in: base,
                bundleID: "com.muses.acceptance.batch23").path
                == "/tmp/muses-path-test/MusesAcceptance/com.muses.acceptance.batch23")
        #expect(MusesDataPaths.acceptanceNamespace(bundleID: "com.muses.acceptance.../escape") == nil)
        #expect(MusesDataPaths.acceptanceNamespace(bundleID: nil) == nil)
    }

    @Test("Existing cache destination absorbs legacy entries and keeps newer collisions")
    func cacheMerge() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appending(path: "old")
        let current = root.appending(path: "current")
        let oldArt = old.appending(path: "artwork")
        let currentArt = current.appending(path: "artwork")
        try FileManager.default.createDirectory(at: oldArt, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentArt, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: oldArt.appending(path: "shared"))
        try Data("current".utf8).write(to: currentArt.appending(path: "shared"))
        try Data("migrated".utf8).write(to: oldArt.appending(path: "legacy-only"))

        try MusesDataPaths.mergeCacheDirectory(from: old, to: current)

        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(try String(contentsOf: currentArt.appending(path: "shared"), encoding: .utf8) == "current")
        #expect(try String(contentsOf: currentArt.appending(path: "legacy-only"), encoding: .utf8) == "migrated")
    }

    @Test("Opt-in large catalog UI fixture is limited to the disposable container")
    func seedCatalog() async throws {
        guard ProcessInfo.processInfo.environment["MUSES_SEED_ACCEPTANCE_CATALOG"] == "1" else { return }
        let directory = URL.homeDirectory.appending(path:
            "Library/Containers/com.muses.acceptance.sep22/Data/Library/Caches/MusesAcceptance/com.muses.acceptance.sep22/public-catalog/v2")
        #expect(directory.resolvingSymlinksInPath().path == directory.path)
        guard directory.resolvingSymlinksInPath().path == directory.path else { return }
        let provider = CachedMusicCatalogProvider(upstream: AcceptanceCatalogFixture(), directory: directory)
        let page = try await provider.search("Muses acceptance large list", kind: .song)
        #expect(page.items.count == 500)
    }

    @Test("Disposable bundles never use the production Keychain service")
    func credentialNamespaces() {
        #expect(KeychainStore.defaultService(bundleID: "com.muses.acceptance.sep22")
                == "com.muses.acceptance.sep22.youtube.oauth")
        #expect(KeychainStore.defaultService(bundleID: "com.muses.validation")
                == "com.muses.validation.youtube.oauth")
        #expect(KeychainStore.defaultService(bundleID: "com.muses.app") == "muses.youtube.oauth")
        #expect(KeychainStore.defaultService(bundleID: nil) == "muses.youtube.oauth")
        #expect(KeychainStore(service: "test.explicit").service == "test.explicit")
    }
}

private struct AcceptanceCatalogFixture: MusicCatalogProviding {
    func search(_ query: String, kind: MusicCatalogKind?) async throws -> MusicCatalogPage {
        let items = (1...500).map { index in
            MusicCatalogItem(id: "video:" + String(format: "fixture%04d", index), kind: .song,
                title: String(format: "Acceptance fixture %04d", index),
                subtitle: "Synthetic scrolling fixture — do not play", artwork: nil,
                artists: [], releases: [], channels: [])
        }
        return .init(items: items, filters: [], next: nil, fetchedAt: .now, region: "US")
    }
    func browse(_ id: String) async throws -> MusicCatalogPage { throw MusicCatalogError.unavailable }
    func next(_ cursor: MusicCatalogCursor) async throws -> MusicCatalogPage { throw MusicCatalogError.unavailable }
    func reset() async {}
}
