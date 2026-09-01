import Testing
import Foundation
@testable import Muses

@Suite("ArtworkCache")
struct ArtworkCacheTests {
    @Test("stores and retrieves by hash")
    func storeRetrieve() throws {
        let cache = ArtworkCache(directory: FileManager.default.temporaryDirectory
            .appending(path: "muses-test-\(UUID().uuidString)"))
        let data = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00]) // jpeg-ish bytes
        let hash = try cache.store(data)
        #expect(!hash.isEmpty)
        let got = cache.data(forHash: hash)
        #expect(got == data)
        #expect(cache.path(forHash: hash) != nil)
    }

    @Test("same data yields same hash")
    func hashStable() throws {
        let cache = ArtworkCache(directory: FileManager.default.temporaryDirectory
            .appending(path: "muses-test-\(UUID().uuidString)"))
        let data = Data(repeating: 0xAB, count: 64)
        let h1 = try cache.store(data)
        let h2 = try cache.store(data)
        #expect(h1 == h2)
    }

}
