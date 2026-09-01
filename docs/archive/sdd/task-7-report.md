# Task 7 Report: Swap call sites and delete old cards

## Status

**DONE**

## Summary

Browsing surfaces now render Task 6 shared objects. Old card/row types are deleted. Click / play matrix matches spec §2. `showsHoverPlay` stays `false`. `showsPlayButton` (default `false`) was added on `SongObjectView` per the carried T6 ruling and is used only on playlist and YouTube-import rows. `swift test --no-parallel`: **408 tests / 70 suites passed**.

## Changes

### Primitive

`SongObjectView` gained `showsPlayButton: Bool = false`. When true, a trailing magenta `play.fill` calls `onPlay`. Default remains false on Songs / album / artist / Liked / derived rows.

`SkeletonCard.Aspect` replaced `DiscoveryCard.Aspect` so skeleton rails still compile after `DiscoveryCard` deletion.

### Step 1 — Home rails

- Hero block → `HeroObjectView` (`onOpen` → `selectedAlbum`, `onPlay` → `playAlbum`, `metadata` = year, `gradient` = `heroGradient`).
- Recently Added / Pinned rails → `AlbumObjectView` size `albumRail`, role `.browse`, `onPlay` → `playAlbum`.
- Recently Played → `AlbumObjectView` role `.play`, `context: recentlyPlayed`, `from: .recently`.
- Imported Playlists → `AlbumObjectView` 160 `.browse`; `onSelect` posts `.musesNavigateYouTubeImport`; `onPlay` plays YT-only import snaps `from: .import` (Task 2 `visibleSnaps` contract).
- All Albums → `AlbumObjectView` size `albumGrid` + pin `.contextMenu`.
- `HomeDiscoveryCardView` / `YouTubeTrendingCard` unchanged (16:9 + `importAsTrack` one-item context).

### Step 2 — Library / Pins / Recently / Playlists / Artists

- Library albums, Recently, Pins albums, artist-album grid → `AlbumObjectView` `.browse` `albumGrid`; pin menu reapplied at the call site; `onPlay` wired for Task 8 hover.
- Playlists browse + Pins playlists → square `AlbumObjectView` `albumGrid`; pin/delete (Pins: pin only) `.contextMenu` at the call site. Artwork is first-item snapshot or `.placeholder`.
- Artists grid → `ArtistObjectView`; context-menu Play / Shuffle kept; `onPlay` is the non-shuffle path.
- `BrowsableAlbumCard` / `BrowsableArtistCard` are thin wrappers around Album/Artist objects with the existing YT badge overlay.

### Step 3 — Song rows

| Surface | Click | Play |
|---|---|---|
| `SongsListView` | `List(..., selection: $selectedSongID)` | double-click / Return / `.trackContextMenu` → visible sorted/filtered list, `from: .songs` |
| Album / artist / Liked / derived detail | `onSelect` **and** `onPlay` play the visible list | `.album` / `.artist` / `.songs` |
| Playlist rows | `onSelect` selects only | `showsPlayButton` + context menu → `playFromList`; `.onMove` + remove kept |
| YouTube album / import rows | `onSelect` selects only | `showsPlayButton` + queue/inbox + context menu → `allSnaps` / `visibleSnaps`, `from: .import` |

`LikedView` still compiles and is **not** in the sidebar.

`.trackContextMenu` stays at call sites.

### Step 4 — New rails

Situational track rail: `AlbumObjectView` role `.play` with **`section.items`**, `from: .songs` (no `context: [snap]`).

Legacy rec albums: `AlbumObjectView` `.browse` + `playAlbum`.

### Step 5 — Deleted types

Deleted files:

- `Features/Shared/DiscoveryCard.swift`
- `Features/Shared/SongCompactRow.swift`

Deleted in-file structs:

- `AlbumCard`, `SongRow` (`LibraryView.swift`)
- `TrackRow` (`AlbumDetailView.swift`)
- `ArtistCard` (`ArtistsView.swift`)
- `PlaylistCard` (`PlaylistsView.swift`)
- `RecentTrackCard`, `YouTubeImportCardSmall` (`HomeView.swift`)
- `PlaylistTrackRow` (`PlaylistDetailView.swift`)
- `YouTubeAlbumTrackRow` (`YouTubeAlbumDetailView.swift`)
- `YouTubeImportItemRow` (`YouTubeImportsView.swift`)
- `TrackSnapshotRow` (`BrowsableViews.swift`)

**Kept (out of scope):** `YouTubeImportCard`, `HomeDiscoveryCardView`, `YouTubeTrendingCard`, Search overlay rows, `YouTubeDiscoveryCard`.

Grep `struct AlbumCard|struct ArtistCard|struct RecentTrackCard|struct TrackRow|struct SongRow|struct PlaylistCard|struct DiscoveryCard|struct SongCompactRow|struct PlaylistTrackRow` under `Muses/Sources/Muses`: **no hits**.

### Step 6 — `context: [snap]` done-bar

Remaining production hits (all allowed):

| File | Why allowed |
|---|---|
| `HomeView.swift` (2) | YouTube discovery / trending `importAsTrack` |
| `GlobalSearchView.swift` | search `importAsTrack` |
| `YouTubeSearchView.swift` | search `importAsTrack` |
| `HistoryView.swift` | History one-shot |
| `InboxView.swift` | Inbox one-shot |
| `MusesApp.swift` | one-shot / deep-link |

Queue history Replay uses `context: [item.track]`, not `[snap]`.

**Not present:** NewView situational; YouTubeImportItemRow; Home Recently Played; playlist in-row Play.

## Verification

| Check | Result |
|---|---|
| `swift test --no-parallel` | PASS — 408 tests, 70 suites, 14.703s |
| Old struct grep | clean |
| `context: [snap]` grep | allow-list only |
| `showsHoverPlay` | default `false`; never passed `true` |
| LikedView in sidebar | not added |
| YouTubeImportCard | management row unchanged |

No rendered screenshots (Task 10).

## Commit

- `3add169` — feat: swap browsing surfaces onto Album, Artist, Song, Hero objects

18 files, +566 / −778, `Muses/Sources/Muses` only.

## Self-review

- **Completeness:** Steps 1–7 done. Matrix, deletions, greps, and tests match the brief.
- **Quality:** Call sites own pin/delete, play context, and `.trackContextMenu`. Primitives stay display-only except the new optional play button.
- **Discipline:** No engine, schema, Search overlay, or YouTubeImportCard changes. Task 2 collection contexts preserved.
- **Testing:** Full suite green.

## Concerns

1. **Songs double-click vs List selection.** Fixed in `e17113b` (see Fix report below). Still not render-verified.
2. **Hero gradient double-paint.** Brief required passing `heroGradient` into `HeroObjectView`. `HomeView` still paints the same gradient on the `ScrollView` background. May look heavier until Task 10.
3. **Playlists browse IA.** 60pt list rows became a 200pt square grid. Spec-mandated; large visual change.
4. **Song rows now always show 44pt art.** Album / playlist / import lists previously had no thumbnail. Intentional object swap; denser rows.
5. **Playlist artwork.** First-item `TrackSnapshot` or placeholder. Not specified in the brief; no playlist artwork field exists.
6. **No rendered check.** Hover is Task 8; visual QA is Task 10.

## Fix report — Songs double-click

**Finding:** Child exclusive single-tap on `SongObjectView` ate the parent Songs-list `.onTapGesture(count: 2)`. Spec §2 requires double-click / Return to play; tap-to-play on that list would be a regression.

**Change:** `playsOnDoubleClick: Bool = false` on `SongObjectView`. When true, `SongRowTapModifier` attaches `count: 2` → `onPlay` and `count: 1` → `onSelect` on the **same** view. `SongsListView` sets `playsOnDoubleClick: true` and no longer wraps a parent double-tap. Other rows stay select-only (or select-and-play via `onSelect`) and are unchanged. Return and `.trackContextMenu` Play were already correct.

**Not done:** No hover. No card-type revival. No `YouTubeImportCard` change.

**Commit:** `e17113b` — fix: recognize Songs double-click on the song row itself

**Tests:** `swift test --no-parallel`

```
✔ Test run with 408 tests in 70 suites passed after 14.518 seconds.
```

Gesture recognition itself is not unit-tested (SwiftUI). Residual: not click-tested in the rendered app.
