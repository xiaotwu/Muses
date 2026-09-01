# Song station grid + Home/New discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Songs and playlist pages use Made-for-You station cards in an adaptive grid on a flat `#1F1F1F` page; Home discovery uses YouTube Music catalog URLs via yt-dlp+cookies; New uses OAuth liked/subscriptions plus local history.

**Architecture:** New `SongStationCard` (square art, bottom overlay title, YouTube mark). `LazyVGrid` adaptive 168–200pt. Home `YTDlpDiscoveryProvider` prefers `fetchPlaylist` on `music.youtube.com` catalog URLs, falls back to `ytsearch`. New adds `YouTubePersonalDiscovery` sections from Data API liked + RD mix.

**Tech Stack:** Swift 6 / SwiftUI / Swift Testing. `swift test --no-parallel --filter ChromeLayoutTests`. Do not change PlaybackService engines or SwiftData schema.

**Spec:** visual language in `docs/superpowers/specs/2026-08-20-muses-apple-music-web-visual.md`. Discovery split: Home = world, New = account.

## Global Constraints

- No `List` system background on Songs / playlist / YouTube import pages.
- Card grid: `GridItem(.adaptive(minimum: 168, maximum: 200), spacing: 16)`, content inset 40.
- Playlist header (art + title + Play) stays; only the song list becomes cards.
- Home must not require OAuth. New OAuth sections appear only when connected; local New rails remain.
- yt-dlp still uses existing cookie settings. Data API still uses existing OAuth session.
- Lazy grids; snapshots in playlist bodies; never `minHeight: count * row`.

---

### Task 1: Station card + grid metrics

**Files:**
- Create: `Muses/Sources/Muses/Features/Shared/SongStationCard.swift`
- Modify: `AppleMusicTokens.swift` (`SongGridMetrics`)
- Modify: `ChromeLayoutTests.swift`

**Interfaces:**
- Produces: `SongGridMetrics.minCard == 168`, `maxCard == 200`, `spacing == 16`. `SongStationCard(title:subtitle:artwork:nowPlaying:onOpen:onPlay:)`.

- [x] **Step 1: Test**

```swift
@Test("song station grid is adaptive 168–200")
func songStationGridMetrics() {
    #expect(SongGridMetrics.minCard == 168)
    #expect(SongGridMetrics.maxCard == 200)
    #expect(SongGridMetrics.spacing == 16)
}
```

- [x] **Step 2: Implement card** — square `ArtworkView`, bottom scrim, title/artist, `YouTubeMark` top-trailing if YouTube, hover Play.

- [x] **Step 3: Run ChromeLayoutTests** PASS. Commit.

---

### Task 2: Songs + playlist pages use the grid, flat background

**Files:**
- Modify: `LibraryView.swift` `SongsListView`
- Modify: `PlaylistDetailView.swift`
- Modify: `YouTubeAlbumDetailView.swift`

**Interfaces:**
- Consumes: `SongStationCard`, `SongGridMetrics`
- Produces: `ScrollView { LazyVGrid { ForEach(snapshots) } }` on `BrandColors.background`. No `List` fill. Playlist keeps 200pt header.

- [x] **Step 1: SongsListView** — drop `List`; `ScrollView` + title + `LazyVGrid`; map tracks to snapshots once per render from `library.allTracks` (already filtered). `.background(BrandColors.background)`. Keep search/sort/play context.

- [x] **Step 2: PlaylistDetailView** — header unchanged; replace `List` with lazy grid of `SongStationCard` from snapshots built in `onAppear`. Context menu keep. Skip visible drag-reorder on the grid.

- [x] **Step 3: YouTubeAlbumDetailView** — same grid under existing header; no page gradient (already removed).

- [x] **Step 4: Tests** `ChromeLayoutTests` PASS. Commit `feat: station-card grid on Songs and playlists`.

---

### Task 3: Home uses YouTube Music catalog URLs

**Files:**
- Create: `Muses/Sources/Muses/Services/Discovery/YouTubeMusicCatalog.swift`
- Modify: `YTDlpDiscoveryProvider.swift`
- Modify: `YTDlpBridge.swift` only if a thin `fetchCatalog(url:)` alias is needed (reuse `fetchPlaylist`)
- Test: `PhaseD3HomeDiscoveryTests.swift` or `ChromeLayoutTests`

**Interfaces:**
- Produces: `YouTubeMusicCatalog.charts`, `.newReleases`, `mix(videoId:)`. Provider `SectionPlan` has `url: String?` and `query: String?`. `runSection` calls `fetchPlaylist(url)` when url is set, else `ytsearch`.

Live URLs (yt-dlp + cookies):

```
charts:        https://music.youtube.com/charts
new_releases:  https://music.youtube.com/new_releases
moods:         https://music.youtube.com/moods
```

If fetch fails, fall back to existing ytsearch strings. Keep listen-again / mixed-for-you as mix URLs when a seed video id exists; otherwise ytsearch.

- [x] **Step 1: Test catalog constants start with `https://music.youtube.com/`.**

- [x] **Step 2: Implement plans + runSection.**

- [x] **Step 3: Existing PhaseD3 tests still pass (provider is injected).** Commit.

---

### Task 4: New uses OAuth liked + mixes

**Files:**
- Create: `Muses/Sources/Muses/Services/Discovery/YouTubePersonalDiscovery.swift`
- Modify: `NewView.swift`
- Modify: `YouTubeAccountService.swift` only if a `likedVideoIds` helper is missing (use `account?.likedVideos`)

**Interfaces:**
- Produces: `YouTubePersonalDiscovery.sections(account:fetchMix:) async -> [HomeSection]`.
  1. Liked — cards from Data API liked videos (no yt-dlp).
  2. Because you liked {title} — `fetchPlaylist(YouTubeMusicCatalog.mix(videoId:))` for the first 1–2 liked ids.
  3. From subscriptions — channel names as ytsearch fallback if no uploads API.
- NewView: if connected, render these sections (station/editorial rails already used on Home) above situational/local.

- [x] **Step 1: Unit test with a fake fetchMix and a fake liked list.**

- [x] **Step 2: Wire NewView `onAppear` to load personal sections. Empty + signed-out → no extra sections, local New stays.**

- [x] **Step 3: Commit** `feat: personalize New from YouTube likes and mixes`.

---

## Self-review

- Songs gray panel → Task 2 (no List background)
- Playlist + Songs Made-for-You cards, many per page, not dense → Task 1–2 (168–200 grid)
- Home world via yt-dlp catalog → Task 3
- New account via OAuth → Task 4
- Engines / schema untouched
