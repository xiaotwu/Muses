import Testing
import Foundation
@testable import Muses

@MainActor
@Suite("StreamURLCache")
struct StreamURLCacheTests {

    @Test("set and get a fresh entry")
    func setGetHit() {
        let cache = StreamURLCache(defaultTTL: 3600)
        let url = URL(string: "https://example.com/audio.m4a")!
        cache.set(videoId: "vid1", url: url)
        #expect(cache.get(videoId: "vid1") == url)
        cache.set(videoId: "vid1", url: URL(string: "https://example.com/lo.m4a")!, quality: "64k")
        #expect(cache.get(videoId: "vid1", quality: "bestaudio") == url)
    }

    @Test("expired entry returns nil and is evicted")
    func expiredEvicted() async throws {
        let cache = StreamURLCache(defaultTTL: 3600)
        let url = URL(string: "https://example.com/audio.m4a")!
        cache.set(videoId: "vid2", url: url, ttl: 0.05)
        // Before expiry
        #expect(cache.get(videoId: "vid2") == url)
        // Wait past expiry
        try await Task.sleep(for: .milliseconds(80))
        #expect(cache.get(videoId: "vid2") == nil)
        // Entry should have been removed on read
        cache.clearExpired()
        #expect(cache.get(videoId: "vid2") == nil)
    }

    @Test("invalidate and clearExpired")
    func invalidateAndClear() {
        let cache = StreamURLCache(defaultTTL: 3600)
        let u1 = URL(string: "https://example.com/a")!
        let u2 = URL(string: "https://example.com/b")!
        cache.set(videoId: "v1", url: u1)
        cache.set(videoId: "v2", url: u2, ttl: -10) // already expired
        // invalidate
        cache.invalidate(videoId: "v1")
        #expect(cache.get(videoId: "v1") == nil)
        // clearExpired sweeps stale entries
        cache.clearExpired()
        #expect(cache.get(videoId: "v2") == nil)
    }
}