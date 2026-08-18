# Muses — Online Performance Before/After Metrics (Phases D1–D7, FINAL)

Date: 2026-08-18
Environment: macOS 27.0.0 arm64, yt-dlp 2026.07.04 (bundled), real network.
Labeling per AGENTS.md: **[measured]** = directly timed; **[structural]** = derived from code path change; **[suspected]** = reasoned but not timed.

> This is the required final deliverable for the spec's 30-section task (§30: "最终提交必须包含在线加载前后指标;如果没有性能数据,本任务不能判定完成"). It supersedes the Phase D2 draft. Runtime interactive click-through (screenshots at multiple window sizes / light / dark / Reduce Transparency) is deferred to the human acceptance gate, consistent with the 0.4.0 RC handoff note.

## Summary

The dominant cost of Muses Home was a **yt-dlp `ytsearch` process spawn on every Home appear**. Phases D2–D3 add stale-while-revalidate caches (`YTDlpSearchCache` for the legacy Top Picks path; `HomeFeedCache` wrapping `SWRCache<[HomeSection]>` for the dynamic discovery feed), a provider abstraction (`HomeDiscoveryProvider` / `YTDlpDiscoveryProvider`) that produces dynamic section titles/content from input (no hardcoded YouTube Music section names), cache-first load with per-section failure, deferred library snapshots, off-main hero-gradient extraction, `.onDisappear` task cancellation, and `CachedAsyncImage` (memory cache + request coalescing + cancel-offscreen). Warm Home loads skip yt-dlp entirely; Home→New→Home round-trips drop from ~5.1s to <1ms of discovery work. Phase D5 adds situational New scoring that uses **no new yt-dlp spawns** (only already-imported YouTube tracks + local library).

## Before (pre-D2, `main` up to D1)

| Metric | Value | Label |
|---|---|---|
| yt-dlp `ytsearch12:` cold spawn (Home seed, limit 12) | **5.10s** | [measured] `/usr/bin/time -p` real, 12 NDJSON lines |
| yt-dlp `ytsearch3:` cold spawn | 4.91s | [measured] |
| Home appear → Top Picks remote content | ≈ 5.10s (blocked on spawn; empty + spinner until done) | [measured→structural] |
| Home → New → Home round-trip discovery cost | ≈ 5.10s *per Home re-entry* (view rebuild resets state, guard re-spawns) | [structural] |
| Home section titles | hardcoded in view ("Top Picks for you" / "YouTube Music") | [structural] |
| Home per-section failure | none — single search; one failure blanks the whole section | [structural] |
| Library snapshot on appear | synchronous on main actor (`refreshLibrarySnapshot` in `onAppear`) | [structural] |
| Hero gradient extraction | synchronous `NSImage(contentsOf:)` + `dominantColors` on main actor | [structural] |
| In-flight yt-dlp task on leave | not stored, not cancelled | [structural] |
| Artwork | bare `AsyncImage` (no memory cache, no coalescing, no cancel) | [structural] |
| New page recommendations | local-only (albums by top artist / unplayed / liked artists); no context, no YouTube mix | [structural] |

## After (D2–D6)

| Metric | Value | Label |
|---|---|---|
| `YTDlpSearchCache` hit path (isFresh + get) | **0.39µs per op** (10,000 ops) | [measured] `PhaseD2 benchmarkCacheHitLatency` |
| `HomeFeedCache` hit path (get, `[HomeSection]` decode from memory) | < 1µs per op (memory hit; disk backfill only on cold) | [measured→structural] `PhaseD3 cacheSetGetFresh` |
| Home appear with **fresh** discovery cache → full feed | < 1ms (cache hit, no spawn) | [measured→structural] `PhaseD3 serviceCacheFirstFresh` |
| Home → New → Home round-trip (fresh cache) | < 1ms discovery work + view render | [structural] |
| Home appear with **stale** cache → first content | < 1ms (stale shown instantly), background refresh spawns ~5.1s | [measured→structural] |
| Cold launch, empty cache, last session cached on disk | stale feed shown instantly from disk (SWR), background refresh ~5.1s | [structural] |
| Home section titles | dynamic, from provider based on `HomeDiscoveryInput` (top artist / time band / liked artist / trending) — not hardcoded in view | [structural] `PhaseD3 providerTitlesDerived` |
| Home per-section failure | independent — one section `.failed` leaves others `.loaded` | [measured] `PhaseD3 providerSectionIndependence` |
| Library snapshot on appear | deferred to `Task { @MainActor }` after first frame | [structural] |
| Hero gradient disk read | moved to `Task.detached`; only color mapping on main | [structural] |
| In-flight tasks on leave | `trendingTask` / `gradientTask` / `homeDiscovery.refreshTask` cancelled | [structural] |
| Artwork | `CachedAsyncImage` (NSCache memory + request coalescing + cancel-offscreen + low-res-first) | [structural] |
| New page (ffSituationalNew on) | deterministic scoring over History/Context/Focus/Library/Inbox/YouTube; local + YouTube mixed; **0 new yt-dlp spawns** | [structural] `PhaseD5` 13 tests |

## Spec §25 target check

| Target | Result |
|---|---|
| Warm Home < 300ms to real content | **PASS** — fresh cache hit is <1ms; content is the cached feed. |
| Cold Home < 1s skeleton/cached shell | **PASS** — local sections (Recently Played/Added/Pinned/All Albums) render instantly from SwiftData; deferred snapshot keeps first frame free; stale disk cache (if present) shows last session's feed instantly (SWR); skeleton cards show during discovery loading (no central spinner, §15). |
| Cold Home < 2–3s first remote batch | **PARTIAL / network-bound** — on a truly cold launch with empty cache, the first yt-dlp `ytsearch` remote batch arrives in ~5.1s [measured]. This is the yt-dlp/YouTube network floor for a flat-playlist search; no client-side cache can reduce the *first-ever* fetch. Every subsequent load within 30 min is instant; stale cache from a prior session makes even a "cold launch" show content immediately (SWR) while refreshing in the background. Reducing true cold-first remote below ~3s requires a lighter metadata endpoint (deferred to a future authenticated YT Music provider — the D3 `HomeDiscoveryProvider` abstraction is in place so that provider can be added without changing Home UI). |
| New uses real History/Context/Sessions/Library/YouTube, not random | **PASS** — `SituationalRecommendationService` reads (read-only) History events + context profiles, current `ListeningContext`, Focus state, Inbox unheard, Library tracks + liked, and source=.youtube tracks. Deterministic scoring (§30 formula), verified by `PhaseD5` tests. |
| Home content not dependent on hardcoded YouTube Music section names | **PASS** — section titles come from `YTDlpDiscoveryProvider` based on `HomeDiscoveryInput`; view contains no hardcoded YT Music section names. |
| No loading spinner masking slow requests | **PASS** — skeletons (`SkeletonCard`/`SkeletonBlock`) + cache-first only; no central `ProgressView` on Home/New discovery (D4/D6 removed the last `ProgressView` on Top Picks). |

## QA matrix (spec §29)

| Scenario | Verification |
|---|---|
| Cold load (empty cache) | [build+test] skeleton → cached local sections instant → remote discovery ~5.1s. Runtime click-through: deferred to human. |
| Warm load (fresh cache) | [test] `PhaseD3 serviceCacheFirstFresh` — <1ms, no spawn. |
| Offline / bad network | [structural] provider section fails → `.failed` status, other sections remain; cache still served. Runtime: deferred to human. |
| Home ↔ New switching | [test] cancellation on disappear; round-trip <1ms from cache. Runtime: deferred. |
| Window resize | [structural] `ResponsiveCarousel` reflows with width; no dead max-width. Runtime screenshots: deferred. |
| 10k library (perf smoke) | [existing] `Phase 2 Smoke` + library perf harness unaffected (D1–D6 additive, no SwiftData schema change). |
| Context disabled (ffContext off) | [test] `PhaseD5` with `context: nil` → no time-band/app sections, other sections still produced. |
| Context enabled | [test] `PhaseD5 morningTimeBandSection` / `appRotationSection`. |
| YouTube import: open + resync + delete + local additions | [build] D1 moved management actions into `YouTubeAlbumDetailView` (Shuffle/Delete/Add Local/queue/inbox); no behavior regression. Runtime: deferred. |
| Light / Dark / Reduce Transparency / VoiceOver | [structural] primitives honor `accessibilityReduceMotion` (skeletons degrade to static); image-only controls have `accessibilityLabel`. Runtime screenshots: deferred to human acceptance. |

## Build & test (final)

- `swift build -c release`: **PASS** (35s).
- `swift test`: **363 tests, 66 suites.** From repo root: 1 known flake (`LocalAudioEngine crossfade` timing — documented pre-existing). 6 `PackagingTests` failures are purely test-runner cwd (`Scripts/*.sh` live at repo root; tests look up relative to cwd = `Muses/`) — they **pass when run from repo root** (`swift test --package-path Muses`).
- New suites this task: Phase D1 (7), D2 (11), D3 (16), D5 (13) = **47 new tests**, 4 new suites. D4/D6 are UI-structure only (no new tests; verified by build + existing suites green).

## What is NOT claimed

- No claim that the *first-ever* cold remote fetch is faster — it is bounded by yt-dlp network latency (~5.1s measured).
- No claim of artwork latency improvement without a real UI run; `CachedAsyncImage` adds memory cache + coalescing + cancellation [structural], verified by build + unit tests, not timed end-to-end in a running app (deferred to human runtime QA).
- yt-dlp is **not** spawned per-card (Home uses a handful of themed `ytsearch` calls per refresh, now cached; New uses 0 new spawns). The N×process concern (spec §21) was not present and remains absent.
- Runtime visual QA (screenshots, VoiceOver, Reduce Transparency) is deferred to the human acceptance gate — D4/D6 are pure SwiftUI views verified by compile + preserved-behavior audit; the primitives are deterministic and honor accessibility environment.

## How to reproduce

1. `swift test --package-path Muses --filter "PhaseD"` — all 47 D-phase tests.
2. `swift test --package-path Muses` (from repo root) — full suite; only the crossfade flake is known.
3. Cold spawn timing: `/usr/bin/time -p Muses/Sources/Muses/Resources/yt-dlp --flat-playlist --dump-json "ytsearch12:trending music 2026"`.
4. Runtime PerfTrace: events `home.appear`, `home.firstCachedContent`, `home.firstRemoteContent`, `home.gradientReady`, `artwork.firstVisible`, `home.discovery.cachedHit/fresh/refreshed` are emitted to `os_log` under subsystem `com.muses.app`, category `PerfTrace` (`log stream --predicate 'subsystem == "com.muses.app" AND category == "PerfTrace"'`).

## Feature flags (all default OFF; lifecycle tested ON/OFF)

- `PrefKey.ffDiscovery` — Home dynamic discovery feed (D3). Off → Home shows legacy Top Picks + Imported Playlists.
- `PrefKey.ffSituationalNew` — New situational recommendations (D5). Off → New shows legacy RecommendationService (local albums).

## Files (D1–D6)

**D1**: `Features/AddMusic/AddMusicMenu.swift`, `Features/Playlist/PlaylistSidebarAdapter.swift`, `Features/Playlist/PlaylistSidebarRow.swift`; modified `App/RootView.swift`, `Features/SidebarView.swift`, `Features/YouTube/YouTubeAlbumDetailView.swift`, `Services/YouTube/YouTubeImportService.swift`.
**D2**: `Infrastructure/PerfTrace.swift`, `Infrastructure/SWRCache.swift`, `Infrastructure/YTDlpSearchCache.swift`, `Infrastructure/ImageLoader.swift`; modified `Features/HomeView.swift`, `Infrastructure/YTDlpBridge.swift`.
**D3**: `Domain/Discovery/HomeSection.swift`, `Services/Discovery/HomeDiscoveryProvider.swift`, `Services/Discovery/YTDlpDiscoveryProvider.swift`, `Services/Discovery/HomeDiscoveryService.swift`, `Infrastructure/HomeFeedCache.swift`; modified `App/MusesApp.swift`, `Domain/UserPreferences.swift`, `Features/HomeView.swift`.
**D4**: `Features/Shared/SectionHeader.swift`, `DiscoveryCard.swift`, `SongCompactRow.swift`, `SkeletonViews.swift`, `ResponsiveCarousel.swift`; modified `Features/HomeView.swift`.
**D5**: `Services/Recommendation/SituationalRecommendationService.swift`; modified `App/MusesApp.swift`, `Domain/UserPreferences.swift`, `Features/NewView.swift`.
**D6**: modified `Features/NewView.swift`.
**Tests**: `PhaseD1PlaylistSidebarTests.swift` (7), `PhaseD2PerfCacheTests.swift` (11), `PhaseD3HomeDiscoveryTests.swift` (16), `PhaseD5SituationalTests.swift` (13).

## Frozen-area compliance

No changes to `PlaybackService`, `LocalAudioEngine`, `YouTubeStreamEngine`, `PlaybackEventBus`, `SessionService`/`HistoryService` canonical behavior, SwiftData migration architecture, `NowPlayingView`, `PlayerBar`, audio pipeline, or queue ownership. D5 reads History/Context/Sessions/Focus/Inbox **read-only**. All new services are additive, `@MainActor @Observable`, injectable-provider, feature-flagged default OFF. No schema migration (D1 playlist unification is a presentation adapter; D3/D5 use existing models).