# Muses — Home / New / Search / Playlists / Sidebar + Online Performance

Implementation plan for the 30-section spec. Follows the spec's D1–D7 order, adapted to the actual codebase. All work is additive and feature-flagged where it changes behavior; navigation cleanup (D1) is unconditional per the spec's explicit demand.

**Frozen (per spec + AGENTS.md):** `PlaybackService`, `LocalAudioEngine`, `YouTubeStreamEngine`, `PlaybackEventBus`, `SessionService`/`HistoryService` canonical behavior, SwiftData migration architecture, `NowPlayingView`, `PlayerBar`, audio pipeline, queue ownership. We only *read* History/Context/Sessions/Inbox/Focus.

**Confirmed decisions:**
1. **Home** = hybrid remote-discovery architecture. Primarily external YouTube/music-world discovery; user history is a *light ranking signal* only. Strong context/history personalization lives in New. Provider abstraction (`HomeDiscoveryProvider`) so a real authenticated YT Music Home provider can be added later without changing Home UI. The brittle internal YT Music API is **not** implemented this phase.
2. **Playlists** = keep `Playlist` and `YouTubeImport` as separate `@Model`s; unify through a single presentation adapter + merged/sorted sidebar collection with a small克制 YouTube source badge. No schema migration. Existing detail paths preserved; future model unification possible without UI change.

---

## Phase D1 — Import cleanup & unified Playlists sidebar

Goal: remove the standalone YouTube Imports sidebar entry, consolidate add-music into the `+` menu, and show YouTube playlists inside the Playlists sidebar section with a source badge. YouTube import functionality is preserved, not deleted.

### New files
- `Features/AddMusic/AddMusicMenu.swift` — a popover/menu presented from the `+` toolbar button. Two entries: **Paste YouTube Link** (single `TextField` + auto-detect: `youtube.com/watch?v=` / `youtu.be/` → video; `list=` param or `/playlist` → playlist) and **Add Local Folder** (opens the existing `ImportSheet`). On a pasted URL: if playlist → `importService.importPlaylist(url:)`; if single video → `importService.importAsTrack`-equivalent single-video import (reuse `YouTubeImportService` single-video path or `YouTubeSearchService.importAsTrack` after a metadata fetch). Reuses existing `YouTubeImportSheet` styling.
- `Features/Playlist/PlaylistSidebarRow.swift` — a single row view rendering either a local `Playlist` or a `YouTubeImport` with a small YouTube source icon (left of name, baseline-aligned, ~12pt, monochrome `play.rectangle`/custom SF Symbol, not a red brand block) for YT items. Routes taps via existing notifications: local → `.musesSelectPlaylist` (object: `Playlist`); YT → `.musesNavigateYouTubeImport` (object: `YouTubeImport`).
- `Features/Playlist/PlaylistSidebarAdapter.swift` — a pure value adapter: `enum SidebarPlaylistItem { case local(Playlist); case youtube(YouTubeImport) }` with `id`, `name`, `sortDate`, `isYouTube`. A function merges `playlistService.fetchAll()` + `@Query` `YouTubeImport`s into one `[SidebarPlaylistItem]` sorted by `sortDate` desc (or pinned-first). This is the presentation adapter — no persistence change.

### Modified files
- `App/RootView.swift` — remove `.youtubeImports` from the `SidebarSection` enum (line 184-191) and its `case` in the detail switch (line 62-63). Change the `+` toolbar button (line 175-179) to present `AddMusicMenu` instead of `ImportSheet` directly (ImportSheet becomes a sub-entry inside AddMusicMenu). Keep `showImport`/`ImportSheet` wiring reachable for the local-folder path.
- `Features/SidebarView.swift` — remove the "YouTube Imports" row (line 46-47). Replace the Playlists `ForEach(playlists)` (line 56-63) with `ForEach(mergedItems)` using `PlaylistSidebarRow`. Refresh both local + YT on `.musesPlaylistsChanged` and on YouTube import changes. Keep `selection = .playlists` highlight; ensure a YT import tap also highlights the Playlists group.
- `Features/YouTube/YouTubeAlbumDetailView.swift` — **absorb the management actions currently only on `YouTubeImportCard`**, since the standalone list is going away. Add: **Shuffle** button, **Delete** (`importService.deleteImport`), **Add Local Tracks** (`+` → `LocalTrackPickerSheet`), **Local additions** sub-section with per-item remove, and per-track **Add to Queue** + **Save to Inbox** on `YouTubeAlbumTrackRow` (mirroring `YouTubeImportItemRow`). Lift `LocalTrackPickerSheet` (YouTubeImportsView.swift:327-398) into its own small file or keep in place and reference it; either way reuse unchanged.
- `Features/YouTube/YouTubeImportsView.swift` — keep the file (it holds `YouTubeImportCard`, `YouTubeImportItemRow`, `LocalTrackPickerSheet` used by the detail view), but `YouTubeImportsView` itself is no longer rendered. Mark it dead/unused or repurpose; do not delete the reusable subviews.

### Verification (D1)
- Build. Unit test `PlaylistSidebarAdapter` merge/sort/badge-flags (pure). Runtime: sidebar shows local + YT playlists merged with badge; tapping each routes to the right detail; `+` → AddMusicMenu → paste a video URL and a playlist URL, both import correctly; Add Local Folder still works; YouTube playlist detail now has Resync/Delete/Add-local/queue/inbox.

---

## Phase D2 — Online performance foundation (metrics-first)

Goal: fix the "feels broken-slow" problem by caching, cancellation, concurrency, and skeletons — **before** touching Home UI. Spec requires before/after metrics.

### New files
- `Infrastructure/PerfTrace.swift` — a tiny timing recorder (`os_signpost` + `CFAbsoluteTimeGetCurrent`) with named intervals: `home.coldFirstContent`, `home.warmFirstContent`, `home.refreshTotal`, `home.switchReturn`, `artwork.firstVisible`. Writes to `os_log` and an in-memory ring buffer dumpable to `artifacts/`. Used to produce before/after numbers.
- `Infrastructure/HomeFeedCache.swift` — disk JSON at `~/Library/Caches/Muses/home-feed.json` + in-memory snapshot. Stores sections (metadata + artwork URLs + `fetchedAt` per section). **Stale-while-revalidate**: read serves cached instantly; `isFresh` threshold 10–30 min; background refresh updates sections independently. Thread-safe (`@MainActor` for the cache object, disk I/O via `Task.detached`).
- `Infrastructure/YTDlpSearchCache.swift` — memoizes `ytsearch` results keyed by `(query, limit)` with TTL (~30 min) so Home re-appear doesn't re-spawn yt-dlp. Lives in front of `YTDlpBridge.searchYouTube`.
- `Infrastructure/ImageLoader.swift` + `Features/Shared/CachedAsyncImage.swift` — `NSCache<NSString, NSImage>` memory cache + in-flight request coalescing (`AsyncAwaitMap`) + low-res-first (`hqdefault.jpg` then `mqdefault.jpg`/`sddefault` upgrade on demand) + cancel-on-disappear. `CachedAsyncImage` replaces bare `AsyncImage` across Home/New/cards.

### Modified files
- `Features/HomeView.swift` — add `.onDisappear` to cancel in-flight `loadTrending` task (store the `Task` handle; currently not stored). Move `updateGradient()` (line 308, blocking `NSImage(contentsOf:)` + `dominantColors`) and `refreshLibrarySnapshot()` (line 97) **off the main-actor appear path** into a `Task.detached` carrying `Sendable` snapshots, then apply on main. Wire `PerfTrace` anchors around first-content paint.
- `Infrastructure/YTDlpBridge.swift` — route `searchYouTube` (line 279) through `YTDlpSearchCache` (transparent to callers; invalidate on demand). No change to `resolveStreamURL`/`fetchPlaylist` (frozen playback path).
- `Features/NewView.swift` — already cancels `computeTask` on disappear (good); ensure section recompute is also cancellable when D5 adds sections.

### Before/after metrics (required deliverable)
Record and commit to `artifacts/online-perf-2026-08-18.md`:
- Cold Home → first meaningful content (current: blank + spinner until yt-dlp search returns).
- Warm Home → first meaningful content.
- Home refresh total.
- Home → New → Home cached return (current: re-runs yt-dlp each time).
- Artwork first visible.
Targets (per spec §25): warm < 300ms to real content; cold < 1s skeleton/cached shell, < 2–3s first remote batch. Report actuals before and after.

### Verification (D2)
- Build. Unit tests: `HomeFeedCache` fresh/stale/SWR transitions; `YTDlpSearchCache` TTL hit/miss/invalidate; `ImageLoader` coalescing + cancel. Runtime: Home re-appear no longer re-spawns yt-dlp (verify via `PerfTrace`/Activity Monitor); navigating Home→New→Home is instant from cache.

---

## Phase D3 — Dynamic Home data (provider abstraction + cache integration)

Goal: Home renders a section feed whose titles/content come from a service, not hardcoded. External YouTube discovery primary; history as light ranking.

### New files
- `Domain/Discovery/HomeSection.swift` — presentation models:
  - `struct HomeSection: Identifiable { id, title, subtitle?, kind: HomeSectionKind, items: [DiscoveryItem], status: SectionStatus }`
  - `enum HomeSectionKind { albumCarousel, playlistCarousel, songGrid, quickPicks, mixed, community }`
  - `enum DiscoveryItem { track(TrackSnapshot), album(Album), playlist(SidebarPlaylistItem), youTube(YouTubeDiscoveryCard) }` (reuse existing domain values; `YouTubeDiscoveryCard` is a small `Sendable` struct: id/title/thumbnailURL/duration — derived from `YTDlpPlaylistEntry` + thumbnail URL).
  - `enum SectionStatus { idle, loading, loaded, failed }`
- `Services/Discovery/HomeDiscoveryProvider.swift` — `protocol HomeDiscoveryProvider { func sections(for input: HomeDiscoveryInput) async -> [HomeSection] }`. `HomeDiscoveryInput` carries top artists, time-of-day, optional light history signals (all `Sendable` values).
- `Services/Discovery/YTDlpDiscoveryProvider.swift` — default provider. Builds a handful of themed `ytsearch` queries (e.g. "{topArtist} top songs", "{genre/era seed}", time-of-day-themed "morning / late night" queries). Section **titles come from the provider** based on input (e.g. "Top songs by {Artist}", "Fresh from {genre}", "Late-night picks") — not hardcoded in the view. Light ranking: reorder results by overlap with user's top artists when available. Partial failure: each section is an independent `async` unit with its own `SectionStatus` (one section failing doesn't fail the feed).
- `Services/Discovery/HomeDiscoveryService.swift` — `@MainActor @Observable final class`. Holds `HomeFeedCache`, the provider, and `@Published var sections: [HomeSection]`. `load()` is **cache-first**: serve cached sections immediately, then background-refresh per section via limited concurrency (4–8, capped `TaskGroup`; no unbounded fan-out). Exposes per-section status for skeleton/error UI. Injectable `enabledProvider` (PrefKey.ffDiscovery) and injectable provider for tests.
- `Tests/MusesTests/PhaseD3HomeDiscoveryTests.swift` — pure-logic: provider→sections mapping, section independence (one failure doesn't poison others), cache SWR ordering, ffDiscovery-off → no-op. Follow `Phase27LocalHardeningTests` style; inject a stub provider + in-memory cache.

### Modified files
- `App/MusesApp.swift` — instantiate `HomeDiscoveryService` (inject `library`, `historyService` for light ranking, `YTDlpBridge`-backed provider) and `.environment(homeDiscoveryService)` (lines ~257-277). Follow the `historyService` wiring pattern.
- `Domain/UserPreferences.swift` — add `static let ffDiscovery = "muses.ff.discovery"` (default OFF).
- `Features/HomeView.swift` — replace the current `topPicksSection` (YouTube search, line 231-263) and `youtubeImportsSection` (line 267-284) with sections sourced from `homeDiscoveryService` when `ffDiscovery` is on; keep the current Recently Played / Recently Added / Pinned / All Albums local sections (they become instant cached sections in the same feed). When `ffDiscovery` off, Home renders the current behavior unchanged.

### Verification (D3)
- Build. Unit tests green. Runtime: Home shows cached feed instantly then sections update independently; section titles are dynamic (change when top artist / time-of-day changes); no hardcoded YT Music section names in the view; one section failing shows that section's failed state while others remain loaded.

---

## Phase D4 — Apple Music-style Home UI

Goal: Home presentation adopts Apple Music macOS hierarchy/spacing/rhythm — not a 1:1 clone. Muses theme, window chrome, PlayerBar, Now Playing unchanged.

### New files (reusable primitives, per AGENTS.md "reusable primitives and semantic surface roles")
- `Features/Shared/SectionHeader.swift` — large section title (~18–22pt) with optional ">" affordance.
- `Features/Shared/DiscoveryCard.swift` — square album/playlist card (artwork + title + subtitle), horizontal-scroll friendly.
- `Features/Shared/SongCompactRow.swift` — compact song row (cover + title + artist + "…") for 2–4 column song grids.
- `Features/Shared/SkeletonCard.swift` / `SkeletonRow.swift` — subtle skeleton placeholders (no central spinner).
- `Features/Shared/ResponsiveCarousel.swift` — horizontal scroll whose visible card count grows with window width (no dead max-width); cards reflow as the window resizes.

### Modified files
- `Features/HomeView.swift` — big "Home" title (~28–34pt) at top. Replace ad-hoc section rendering with the new primitives: `SectionHeader` + `ResponsiveCarousel`/`SongCompactRow`. Skeletons while a section is `loading` and no cached data; cached data shows immediately. Preserve all existing behaviors: hero tap → album detail, card play actions, contextual playback context (`from: .recently`, etc.), focus-mode suppression of discovery sections. Keep current B&W theme and Liquid Glass conventions; no red brand blocks.

### Verification (D4)
- Build. Runtime screenshots at multiple window sizes + light/dark/Reduce Transparency: legibility holds, cards increase with width, skeleton-then-content transition is calm (no spinner), PlayerBar/Now Playing untouched. VoiceOver labels on new image-only controls.

---

## Phase D5 — Situational New (data)

Goal: New becomes "Muses intelligence for this moment" — deterministic scoring over History/Context/Sessions/Focus/Inbox/Library/YouTube, mixing local + YouTube. No LLM.

### New files
- `Services/Recommendation/SituationalRecommendationService.swift` — `@MainActor @Observable final class`. Reads (read-only) `HistoryService.events`/`recap`/`contextProfiles`, `ContextService.capture()`, `SessionService.currentSessionId`/restore offer, `FocusService.isActive`, `InboxService` (via context query), `LibraryService`, and imported YouTube playlist tracks. Produces `[RecommendationSection]` where each section has a context-derived title (e.g. "Good morning", "Your coding rotation", "Late-night favorites", "Continue Focus Session", "Recently obsessed with").
  - Pure scoring in a `nonisolated static func plan(...)` (mirror `RecommendationService.plan`) carrying `Sendable` value snapshots, run via `Task.detached`.
  - `score = listeningAffinity + contextAffinity + recencyWeight + playlistAffinity + discoveryWeight - recentOverplayPenalty - skipPenalty`. Skip/overplay signals from `ListeningEvent` (verify fields at implementation; approximate from play/completion if explicit skip absent — never fabricate).
  - **Mixes local + YouTube** in the same sections (local FLAC/MP3 + YouTube tracks from imported playlists). No new yt-dlp spawns for New — uses already-imported YouTube tracks + cached Home discovery items.
  - Context profiles: morning (08–11), late night (23–05), active-app (e.g. VS Code → "coding"), headphone state, focus mode. When Focus active, New becomes focus-only (continue session, instrumental, low-distraction) per spec §11.
  - Injectable providers + `enabledProvider` (PrefKey.ffSituationalNew), default OFF. When off, `NewView` keeps using `RecommendationService`.
- `Tests/MusesTests/PhaseD5SituationalTests.swift` — pure-logic scoring tests: morning vs late-night vs coding vs focus produce different sections; local+YouTube mix; overplay/skip penalties reduce scores; ffSituationalNew-off → no-op/returns nil. Inject stub history/context/focus providers (Phase17 pattern).

### Modified files
- `App/MusesApp.swift` — instantiate + inject `SituationalRecommendationService`.
- `Domain/UserPreferences.swift` — add `static let ffSituationalNew = "muses.ff.situationalNew"` (default OFF).
- `Features/NewView.swift` — when `ffSituationalNew` on, render sections from `SituationalRecommendationService` instead of `RecommendationService`. Keep existing empty/focus states. Recompute on context/focus/play changes with cancellation.

### Verification (D5)
- Build. Unit tests green. Runtime: morning shows morning rotation; with VS Code active + Context enabled shows coding rotation; late night shows late-night; Focus mode shows focus sections; local + YouTube tracks mixed in the same section.

---

## Phase D6 — Apple Music-style New UI

Goal: New presentation matches Home's design language.

### Modified files
- `Features/NewView.swift` — big "New" title (~28–34pt; keep the "New" name per spec — don't rename to "For You" this phase). Use the D4 primitives: hero "For this moment" cards, `Because you've been listening to…` carousel, song grids, `Rediscover`, `From your YouTube playlists`. Skeletons for loading. Responsive layout. Keep Muses theme.

### Verification (D6)
- Build. Screenshots at multiple sizes/appearances; legibility + Reduce Transparency; PlayerBar/Now Playing untouched.

---

## Phase D7 — QA + final metrics

### Runtime QA matrix (spec §29)
Cold load · warm load · offline · bad network · Home↔New switching · window resize · 10k library (existing perf smoke harness) · Context disabled · Context enabled · YouTube import playlist open + resync + delete + local additions.

### Final deliverables
- `artifacts/online-perf-2026-08-18.md` — before/after metrics table (the 5 timings) with actuals and target comparison. **This is required for task completion (spec §30).**
- Updated memory file for this phase.
- All builds + tests green (existing 316 tests + new D1–D6 suites). Pre-existing known flakes noted, not introduced.

---

## Cross-cutting rules honored
- No spinner masking (spec §15): skeletons + cache-first only.
- Home cache-first + background refresh + per-section failure (§16–18).
- No hardcoded YT Music section names in views (§3): titles come from provider/service.
- New uses real History/Context/Sessions/Library/YouTube, not random (§10–12).
- yt-dlp kept out of per-card metadata fan-out (§21): Home uses a few themed searches, cached; New uses no new yt-dlp.
- Image lazy load + memory cache + coalescing + cancel-offscreen + low-res-first (§22).
- Request cancellation on page switch (§23); search debounce/cancellation preserved (§24).
- Frozen areas untouched; all new services are additive, `@MainActor @Observable`, injectable-provider, feature-flagged default OFF.
- Bilingual `tr(en, zh)` convention maintained in new UI strings.