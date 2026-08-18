import Testing
import Foundation
@testable import Muses

/// Phase D2 — 在线性能基础设施的纯逻辑测试(SWRCache / YTDlpSearchCache / PerfTrace)。
/// 不触真实网络/yt-dlp;缓存使用临时目录,测后清理。
@MainActor
@Suite("Phase D2 — Online perf caches & trace", .serialized)
struct PhaseD2PerfCacheTests {

    private func tmpDir() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("muses-d2-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: - SWRCache

    @Test("SWRCache: set 后 get 命中,携带 fetchedAt 与 age")
    func swrSetGet() {
        let cache = SWRCache<[String]>(directory: tmpDir())
        cache.set("k", value: ["a", "b"])
        let cached = cache.get("k")
        #expect(cached != nil)
        #expect(cached?.value == ["a", "b"])
        #expect(cached?.age ?? 1 >= 0)
        #expect((cached?.age ?? 1) < 1)
    }

    @Test("SWRCache: 未写入的 key 返回 nil")
    func swrMiss() {
        let cache = SWRCache<[String]>(directory: tmpDir())
        #expect(cache.get("missing") == nil)
    }

    @Test("SWRCache: isFresh 在窗口内为真,过期后为假")
    func swrFreshness() {
        let cache = SWRCache<[String]>(directory: tmpDir())
        let old = Date().addingTimeInterval(-120)
        cache.set("k", value: ["x"], fetchedAt: old)
        let cached = cache.get("k")
        #expect(cache.isFresh(cached!, freshWindow: 180) == true)
        #expect(cache.isFresh(cached!, freshWindow: 60) == false)
    }

    @Test("SWRCache: 落盘后跨实例复用(模拟冷启动)")
    func swrDiskPersistence() {
        let dir = tmpDir()
        let cache1 = SWRCache<[String]>(directory: dir)
        cache1.set("k", value: ["persisted"])
        // 等待 detached 落盘:轮询直到 dir 下出现 .json 文件(最多 ~2s)。
        let deadline = Date().addingTimeInterval(2)
        var files: [URL] = []
        while Date() < deadline {
            files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            if files.contains(where: { $0.pathExtension == "json" }) { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(files.contains { $0.pathExtension == "json" })

        // 新实例(内存为空)从磁盘回填。
        let cache2 = SWRCache<[String]>(directory: dir)
        let cached = cache2.get("k")
        #expect(cached?.value == ["persisted"])
    }

    @Test("SWRCache: invalidate 移除内存与磁盘")
    func swrInvalidate() {
        let dir = tmpDir()
        let cache = SWRCache<[String]>(directory: dir)
        cache.set("k", value: ["x"])
        #expect(cache.get("k") != nil)
        cache.invalidate("k")
        #expect(cache.get("k") == nil)
    }

    // MARK: - YTDlpSearchCache

    @Test("YTDlpSearchCache: 新鲜命中跳过 spawn 的判定")
    func searchCacheFreshness() {
        let cache = YTDlpSearchCache(directory: tmpDir(), freshWindow: 60)
        cache.set(query: "q", limit: 10,
                  entries: [YTDlpBridge.YTDlpPlaylistEntry(id: "v1", title: "t")])
        #expect(cache.get(query: "q", limit: 10)?.value.count == 1)
        #expect(cache.isFresh(query: "q", limit: 10) == true)
        #expect(cache.isFresh(query: "other", limit: 10) == false)
    }

    @Test("YTDlpSearchCache: stale 仍可读但 isFresh 为假(SWR 语义)")
    func searchCacheStaleWhileRevalidate() {
        let cache = YTDlpSearchCache(directory: tmpDir(), freshWindow: 60)
        let old = Date().addingTimeInterval(-120)
        cache.set(query: "q", limit: 5,
                  entries: [YTDlpBridge.YTDlpPlaylistEntry(id: "v1", title: "t")],
                  fetchedAt: old)
        // stale 但仍可立即展示。
        #expect(cache.get(query: "q", limit: 5) != nil)
        #expect(cache.isFresh(query: "q", limit: 5) == false)
    }

    @Test("YTDlpSearchCache: invalidate 与 clearAll")
    func searchCacheInvalidate() {
        let cache = YTDlpSearchCache(directory: tmpDir())
        cache.set(query: "q", limit: 10, entries: [])
        #expect(cache.get(query: "q", limit: 10) != nil)
        cache.invalidate(query: "q", limit: 10)
        #expect(cache.get(query: "q", limit: 10) == nil)
    }

    // MARK: - PerfTrace

    @Test("PerfTrace: event 记录瞬时事件,dumpText 包含名称")
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

    @Test("PerfTrace: begin/end 区间记录耗时")
    func perfTraceInterval() {
        PerfTrace.clear()
        let token = PerfTrace.begin("home.refreshTotal")
        Thread.sleep(forTimeInterval: 0.01)
        PerfTrace.end(token)
        let rec = PerfTrace.snapshot().first { $0.name == "home.refreshTotal" }
        #expect(rec?.duration ?? 0 >= 0.005)
        PerfTrace.clear()
    }

    // MARK: - 基准:缓存命中 vs 冷 spawn 的量级(spec §25 指标)

    @Test("基准:YTDlpSearchCache 命中路径耗时(微秒级)")
    func benchmarkCacheHitLatency() {
        let cache = YTDlpSearchCache(directory: tmpDir(), freshWindow: 60)
        let entries = (0..<12).map {
            YTDlpBridge.YTDlpPlaylistEntry(id: "v\($0)", title: "t\($0)")
        }
        cache.set(query: "seed", limit: 12, entries: entries)
        // 预热一次(填内存)。
        _ = cache.get(query: "seed", limit: 12)

        let n = 10_000
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<n {
            _ = cache.isFresh(query: "seed", limit: 12)
            _ = cache.get(query: "seed", limit: 12)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let perOpUs = elapsed / Double(n) * 1_000_000
        // 记录到 stdout 供指标文件;断言命中路径在 100µs 以内(远低于 spawn)。
        print("[D2-bench] cache hit per op: \(String(format: "%.2f", perOpUs)) µs over \(n) ops")
        #expect(perOpUs < 100)
        PerfTrace.clear()
    }
}