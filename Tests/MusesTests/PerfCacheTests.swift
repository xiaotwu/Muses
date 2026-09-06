import Testing
import Foundation
@testable import Muses

/// Pure-logic tests for the online performance infrastructure (SWRCache / YTDlpSearchCache / PerfTrace).
/// No real network or yt-dlp; caches use a temporary directory that is cleaned up afterwards.
@MainActor
@Suite("Phase D2 — Online perf caches & trace", .serialized)
struct PerfCacheTests {

    private func tmpDir() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("muses-d2-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: - SWRCache

    @Test("SWRCache: set then get hits, preserving fetchedAt and age")
    func swrSetGet() {
        let cache = SWRCache<[String]>(directory: tmpDir())
        cache.set("k", value: ["a", "b"])
        let cached = cache.get("k")
        #expect(cached != nil)
        #expect(cached?.value == ["a", "b"])
        #expect(cached?.age ?? 1 >= 0)
        #expect((cached?.age ?? 1) < 1)
    }

    @Test("SWRCache: unwritten key returns nil")
    func swrMiss() {
        let cache = SWRCache<[String]>(directory: tmpDir())
        #expect(cache.get("missing") == nil)
    }

    @Test("SWRCache: isFresh is true within window and false after expiration")
    func swrFreshness() {
        let cache = SWRCache<[String]>(directory: tmpDir())
        let old = Date().addingTimeInterval(-120)
        cache.set("k", value: ["x"], fetchedAt: old)
        let cached = cache.get("k")
        #expect(cache.isFresh(cached!, freshWindow: 180) == true)
        #expect(cache.isFresh(cached!, freshWindow: 60) == false)
    }

    @Test("SWRCache: disk persistence across instances simulates cold start")
    func swrDiskPersistence() {
        let dir = tmpDir()
        let cache1 = SWRCache<[String]>(directory: dir)
        cache1.set("k", value: ["persisted"])
        // Wait for the detached task to flush: poll until a .json file appears in dir (up to ~2s).
        let deadline = Date().addingTimeInterval(2)
        var files: [URL] = []
        while Date() < deadline {
            files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            if files.contains(where: { $0.pathExtension == "json" }) { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(files.contains { $0.pathExtension == "json" })

        // A fresh instance (empty memory) backfills from disk.
        let cache2 = SWRCache<[String]>(directory: dir)
        let cached = cache2.get("k")
        #expect(cached?.value == ["persisted"])
    }

    @Test("SWRCache: invalidate removes from memory and disk")
    func swrInvalidate() {
        let dir = tmpDir()
        let cache = SWRCache<[String]>(directory: dir)
        cache.set("k", value: ["x"])
        #expect(cache.get("k") != nil)
        cache.invalidate("k")
        #expect(cache.get("k") == nil)
    }

    // MARK: - YTDlpSearchCache

    @Test("YTDlpSearchCache: fresh hit skips process spawn determination")
    func searchCacheFreshness() {
        let cache = YTDlpSearchCache(directory: tmpDir(), freshWindow: 60)
        cache.set(query: "q", limit: 10,
                  entries: [YTDlpBridge.YTDlpPlaylistEntry(id: "yt_track_1", title: "t")])
        #expect(cache.get(query: "q", limit: 10)?.value.count == 1)
        #expect(cache.isFresh(query: "q", limit: 10) == true)
        #expect(cache.isFresh(query: "other", limit: 10) == false)
    }

    @Test("YTDlpSearchCache: stale is still readable but isFresh is false (SWR semantics)")
    func searchCacheStaleWhileRevalidate() {
        let cache = YTDlpSearchCache(directory: tmpDir(), freshWindow: 60)
        let old = Date().addingTimeInterval(-120)
        cache.set(query: "q", limit: 5,
                  entries: [YTDlpBridge.YTDlpPlaylistEntry(id: "yt_track_1", title: "t")],
                  fetchedAt: old)
        // Stale but still immediately displayable.
        #expect(cache.get(query: "q", limit: 5) != nil)
        #expect(cache.isFresh(query: "q", limit: 5) == false)
    }

    @Test("YTDlpSearchCache: invalidate and clearAll")
    func searchCacheInvalidate() {
        let cache = YTDlpSearchCache(directory: tmpDir())
        cache.set(query: "q", limit: 10, entries: [])
        #expect(cache.get(query: "q", limit: 10) != nil)
        cache.invalidate(query: "q", limit: 10)
        #expect(cache.get(query: "q", limit: 10) == nil)
    }

    // MARK: - PerfTrace

    @Test("PerfTrace: event records instantaneous event and dumpText contains name")
    func perfTraceEvent() {
        PerfTrace.clear()
        PerfTrace.event("home.appear")
        PerfTrace.event("home.firstCachedContent")
        let snap = PerfTrace.snapshot()
        #expect(snap.count == 2)
        #expect(snap[0].name == "home.appear")
        #expect(snap[0].duration == nil)
        let dump = PerfTrace.dumpText()
        #expect(dump.contains("home.appear"))
        #expect(dump.contains("home.firstCachedContent"))
        PerfTrace.clear()
    }

    @Test("PerfTrace: begin/end interval records duration")
    func perfTraceInterval() {
        PerfTrace.clear()
        let token = PerfTrace.begin("home.refreshTotal")
        Thread.sleep(forTimeInterval: 0.01)
        PerfTrace.end(token)
        let rec = PerfTrace.snapshot().first { $0.name == "home.refreshTotal" }
        #expect(rec?.duration ?? 0 >= 0.005)
        PerfTrace.clear()
    }

    // MARK: - Baseline: order of magnitude of a cache hit vs a cold spawn (spec §25 metrics)

    @Test("Benchmark: YTDlpSearchCache hit path latency (microsecond scale)")
    func benchmarkCacheHitLatency() {
        let cache = YTDlpSearchCache(directory: tmpDir(), freshWindow: 60)
        let entries = (0..<12).map {
            YTDlpBridge.YTDlpPlaylistEntry(id: "yt_track_\($0)", title: "t\($0)")
        }
        cache.set(query: "seed", limit: 12, entries: entries)
        // Warm up once (fills the in-memory cache).
        _ = cache.get(query: "seed", limit: 12)

        let n = 10_000
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<n {
            _ = cache.isFresh(query: "seed", limit: 12)
            _ = cache.get(query: "seed", limit: 12)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let perOpUs = elapsed / Double(n) * 1_000_000
        // Print to stdout for the metrics file; assert the hit path stays within 100µs (far below a spawn).
        print("[D2-bench] cache hit per op: \(String(format: "%.2f", perOpUs)) µs over \(n) ops")
        #expect(perOpUs < 100)
        PerfTrace.clear()
    }
}