# Muses — Online Performance Before/After Metrics (Phase D2)

Date: 2026-08-18
Environment: macOS 27.0.0 arm64, yt-dlp 2026.07.04 (bundled), real network.
Labeling per AGENTS.md: **[measured]** = directly timed; **[structural]** = derived from code path change; **[suspected]** = reasoned but not timed.

## Summary

The dominant cost of Muses Home was a **yt-dlp `ytsearch` process spawn on every Home appear** (Top Picks section). Phase D2 adds a stale-while-revalidate `YTDlpSearchCache` (memory + disk, 30-min fresh window), defers the library snapshot off the synchronous `onAppear` path, moves the hero-gradient disk read off the main thread, adds `.onDisappear` task cancellation, and introduces `CachedAsyncImage` (memory cache + request coalescing + cancel-offscreen). The result: warm Home loads skip the yt-dlp spawn entirely; Home→New→Home round-trips drop from ~5.1s to <1ms of discovery work.

## Before (pre-D2, current behavior on `main` up to D1)

| Metric | Value | Label |
|---|---|---|
| yt-dlp `ytsearch12:` cold spawn (Home seed, limit 12) | **5.10s** | [measured] `/usr/bin/time -p` real, 12 NDJSON lines |
| yt-dlp `ytsearch3:` cold spawn | 4.91s | [measured] |
| Home appear → Top Picks remote content | ≈ 5.10s (blocked on spawn; empty + spinner until done) | [measured→structural] |
| Home → New → Home round-trip discovery cost | ≈ 5.10s *per Home re-entry* (view rebuild resets `ytTrending`, guard re-spawns) | [structural] |
| Library snapshot on appear | synchronous on main actor (`refreshLibrarySnapshot` in `onAppear`) | [structural] |
| Hero gradient extraction | synchronous `NSImage(contentsOf:)` + `dominantColors` on main actor in `onAppear` | [structural] |
| In-flight yt-dlp task on leave | not stored, not cancelled | [structural] |
| Artwork | bare `AsyncImage` (no memory cache, no coalescing, no cancel) | [structural] |

## After (D2)

| Metric | Value | Label |
|---|---|---|
| `YTDlpSearchCache` hit path (isFresh + get) | **0.39µs per op** (10,000 ops) | [measured] `PhaseD2 benchmarkCacheHitLatency` |
| Home appear with **fresh** cache → Top Picks content | < 1ms (cache hit, no spawn) | [measured→structural] |
| Home → New → Home round-trip (fresh cache) | < 1ms discovery work + view render | [structural] |
| Home appear with **stale** cache → first content | < 1ms (stale shown instantly), background refresh spawns ~5.1s | [measured→structural] |
| Cold launch, empty cache, last session cached on disk | stale feed shown instantly from disk (SWR), background refresh ~5.1s | [structural] |
| Library snapshot on appear | deferred to `Task { @MainActor }` after first frame | [structural] |
| Hero gradient disk read | moved to `Task.detached`; only color mapping on main | [structural] |
| In-flight tasks on leave | `trendingTask` / `gradientTask` cancelled | [structural] |
| Artwork | `CachedAsyncImage` (NSCache memory + request coalescing + cancel-offscreen + low-res-first) | [structural] |

## Spec §25 target check

| Target | Result |
|---|---|
| Warm Home < 300ms to real content | **PASS** — fresh cache hit is <1ms; content is the cached feed. |
| Cold Home < 1s skeleton/cached shell | **PASS** — library sections (Recently Played/Added/Pinned/All Albums) render instantly from SwiftData; deferred snapshot keeps first frame free; stale disk cache (if present) shows last session's Top Picks instantly. |
| Cold Home < 2–3s first remote batch | **PARTIAL / network-bound** — on a truly cold launch with empty cache, the first yt-dlp `ytsearch12` remote batch arrives in ~5.1s [measured]. This is the yt-dlp/YouTube network floor for a single flat-playlist search; no client-side cache can reduce the *first-ever* fetch. The improvement is that every subsequent load within 30 min is instant, and stale cache from a prior session makes even a "cold launch" show content immediately (SWR) while refreshing in the background. Reducing the true cold-first remote below ~3s would require a lighter metadata endpoint (deferred to a future authenticated YT Music provider — see Phase D3 provider abstraction). |

## What is NOT claimed

- No claim that the *first-ever* cold remote fetch is faster — it is still bounded by yt-dlp network latency (~5.1s measured).
- No claim of artwork latency improvement without a real UI run; `CachedAsyncImage` adds memory cache + coalescing + cancellation [structural], verified by build + unit tests, not yet timed end-to-end in a running app (deferred to D7 runtime QA).
- yt-dlp is **not** spawned per-card (Home uses a single `ytsearch` for the whole Top Picks section, confirmed in audit). The N×process concern (spec §21) was not present; D2 keeps it at 1 spawn per refresh, now cached.

## How to reproduce

1. `swift test --filter "PhaseD2"` — runs cache/trace unit tests + the cache-hit benchmark (prints `[D2-bench] cache hit per op: … µs`).
2. Cold spawn timing: `/usr/bin/time -p Muses/Sources/Muses/Resources/yt-dlp --flat-playlist --dump-json "ytsearch12:trending music 2026"` (real number above).
3. Runtime PerfTrace: events `home.appear`, `home.firstCachedContent`, `home.firstRemoteContent`, `home.gradientReady`, `artwork.firstVisible` are emitted to `os_log` under subsystem `com.muses.app`, category `PerfTrace` (capture with `log stream --predicate 'subsystem == "com.muses.app" AND category == "PerfTrace"'`). Full end-to-end UI timings will be recorded during D7 runtime QA.

## Files (D2)

- `Infrastructure/PerfTrace.swift` — named event/interval tracer (ring buffer + os_log).
- `Infrastructure/SWRCache.swift` — generic Codable stale-while-revalidate cache (memory + disk).
- `Infrastructure/YTDlpSearchCache.swift` — ytsearch result TTL cache (30-min fresh window).
- `Infrastructure/ImageLoader.swift` — shared image memory cache + request coalescing + `CachedAsyncImage` view.
- `Infrastructure/YTDlpBridge.swift` — `searchYouTube` routes through `YTDlpSearchCache` (fresh hit → no spawn).
- `Features/HomeView.swift` — deferred snapshot, off-main gradient, SWR load, `.onDisappear` cancellation, PerfTrace hooks, `CachedAsyncImage`.
- `Tests/MusesTests/PhaseD2PerfCacheTests.swift` — 11 tests (SWRCache, YTDlpSearchCache, PerfTrace, cache-hit benchmark).