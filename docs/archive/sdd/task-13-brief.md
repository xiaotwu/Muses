### Task 13: 阶段 1 集成验收与 e2e 冒烟

**Files:**
- Create: `Muses/Tests/MusesTests/Phase1SmokeTests.swift`
- 无新源码 — 纯集成验收测试。

**Interfaces:**
- Consumes: all Phase 1 services — `makeModelContainer(inMemory:)`, `MetadataService(artworkCache:)`, `ArtworkCache(directory:)`, `LibraryService`, `LocalAudioEngine`, `QueueService`, `PlaybackService`, `TrackSnapshot(from:)`, `makeSilentWav(at:seconds:)`.

**Purpose:** End-to-end smoke test that exercises the full Phase 1 flow: scan a temp directory of generated WAV files → list albums/tracks → play first track via PlaybackService → advance to next track. Verifies the services compose correctly across the domain → infrastructure → services → playback layers.

**Verified API facts:**
- `makeModelContainer(inMemory: Bool) throws -> ModelContainer` — top-level function.
- `MetadataService(artworkCache: ArtworkCache)` — init.
- `ArtworkCache(directory: URL)` — init.
- `LibraryService(modelContainer: ModelContainer, metadata: MetadataService)` — init.
- `library.addScanRoot(_ url: URL, watch: Bool) async throws` — scans the dir.
- `library.allAlbums() -> [Album]`, `library.allTracks() -> [Track]`.
- `LocalAudioEngine()` — init (conforms to PlayerEngine).
- `QueueService()` — init.
- `PlaybackService(engine: any PlayerEngine, queue: QueueService)` — init.
- `playback.playTrack(_ track: TrackSnapshot, context: [TrackSnapshot], from: QueueSource)` — kicks off async load.
- `playback.state.track?.title` — observable.
- `playback.next()` — advances queue + loads.
- `TrackSnapshot(from track: Track)` — snapshot init.
- `makeSilentWav(at:seconds:)` — top-level helper in the test module (defined in LibraryServiceTests.swift, visible module-wide). Reuse it, do NOT redefine it.
- `@MainActor` is required on the test struct because it touches @MainActor services (LibraryService, LocalAudioEngine, QueueService, PlaybackService). All prior test structs that touch these services use `@MainActor` (LocalAudioEngineTests, QueueServiceTests, PlaybackServiceTests). Apply it here too.

- [ ] **Step 1: 写端到端冒烟测试**

`Muses/Tests/MusesTests/Phase1SmokeTests.swift`:
```swift
import Testing
import Foundation
@testable import Muses

@MainActor
@Suite("Phase 1 Smoke")
struct Phase1SmokeTests {
    @Test("full flow: scan → list albums → play → advance")
    func fullFlow() async throws {
        let cacheDir = FileManager.default.temporaryDirectory.appending(path: "muses-smoke-\(UUID().uuidString)")
        let container = try makeModelContainer(inMemory: true)
        let meta = MetadataService(artworkCache: ArtworkCache(directory: cacheDir))
        let library = LibraryService(modelContainer: container, metadata: meta)
        let dir = FileManager.default.temporaryDirectory.appending(path: "muses-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in 0..<2 {
            try makeSilentWav(at: dir.appending(path: "tone\(n).wav"), seconds: 1)
        }

        try await library.addScanRoot(dir, watch: false)
        #expect(library.allAlbums().count >= 1)
        let tracks = library.allTracks()
        #expect(tracks.count == 2)

        let engine = LocalAudioEngine()
        let queue = QueueService()
        let pb = PlaybackService(engine: engine, queue: queue)

        let ctx = tracks.map { TrackSnapshot(from: $0) }
        pb.playTrack(ctx[0], context: ctx, from: .album)
        try await Task.sleep(for: .milliseconds(150))
        #expect(pb.state.track?.title == ctx[0].title)

        pb.next()
        try await Task.sleep(for: .milliseconds(150))
        #expect(pb.state.track?.title == ctx[1].title)
    }
}
```

**Notes on the plan's original test code (fixes applied here):**
- Added `@MainActor` to the test struct (the plan omitted it; required because LibraryService/LocalAudioEngine/QueueService/PlaybackService are all @MainActor-isolated). Matches the convention in LocalAudioEngineTests/QueueServiceTests/PlaybackServiceTests.
- The plan constructed `ArtworkCache(directory: ...temporaryDirectory.appending(path: "muses-smoke"))` with a fixed name — changed to a UUID-suffixed dir to avoid collisions across test runs (consistent with the test-temp-dir hygiene noted as a Task 3 deferred minor).
- Added `try await Task.sleep(for: .milliseconds(150))` after `playTrack` and after `next()` — these fire `Task { await load(...) }` internally, so the state.track update is async. The sleep gives the Task a tick to run before asserting. 150ms is generous enough for the async load + engine play to set state.track.
- The plan asserted `pb.state.track?.title == ctx[0].title` immediately after `playTrack` (which is sync but the load is async) — without the sleep this would race. The sleep fixes the race.
- Cleaned up the cacheDir naming to match dir naming (both UUID-suffixed). No explicit cleanup of temp dirs (matches the Task 3 deferred-minor convention — temp dirs leak on reruns; not blocking).

- [ ] **Step 2: 运行全部测试**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift test`
Expected: 全部 PASS — should be 26 tests across 10 suites (the 25 existing + this new Phase1SmokeTests suite's 1 test). Confirm the count.

- [ ] **Step 3: 人工 e2e 冒烟 (optional, GUI)**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift run`
验收清单:
- 窗口打开,深色背景,侧边栏 4 项 + Settings。
- 点工具栏 `+`,选含音频的目录,扫描进度条出现后封面墙填充。
- 点击封面进入专辑详情页,背景渐变取自封面色。
- 点曲目行 → PlayerBar 显示封面/标题,开始播放,进度推进。
- 暂停/恢复、拖动进度 seek、上一首/下一首、音量调节均工作。
- Hi-Res 文件显示绿色 Hi-Res 徽标。
Skip if headless — the automated smoke test is the gate for Phase 1 acceptance.

- [ ] **Step 4: Commit**

Run:
```bash
cd /Users/xiaotwu/Code/xyz
git add -A
git commit -m "test: phase 1 end-to-end smoke (scan→list→play→advance)"
```

---