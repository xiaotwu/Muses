# Task 5 Report: Display-only ArtworkView swaps

## Status

**DONE_WITH_CONCERNS**

## Summary

Every listed feature `body` now displays via `ArtworkView(source:targetSize:)`. Card types stay. `ImageLoader.loadLocal` downsamples with `NSBitmapImageRep` + `NSGraphicsContext` inside `Task.detached` (no `lockFocus`, no `URLSession` for local files). Album/artist `extractGradient` loads off-main through `ArtworkSource.loadNSImage()` with identity + cancel checks. Done-bar grep has no feature-`body` `NSImage(byReferencing:)` / `contentsOf:` / `.cached(` hits.

## Changes

### Carried Task 4 must-fixes

- Explicit `targetSize` at every current `ArtworkView` caller:

| Site | targetSize |
|---|---|
| CoverArtModeView | 480 |
| VinylModeView | 288 (`discSize * 0.6`) |
| MiniPlayerView | 180 |
| UpNextPreview | 36 |
| Browsable derived headers | 160 |
| Browsable cards | 200 |
| PlayerBar | 52 |
| Search library rows | 40 |
| AlbumCard / Home hero | 200 |
| ArtistCard | 200, `clipCircle: true` |
| ArtistDetail header | 180, `clipCircle: true` |
| AlbumDetail hero | 240, `cornerRadius: 12` |
| DiscoveryCard | `size` (150 typical) |
| RecentTrackCard | 120 |
| NewView situational card | 140 |
| SongRow | 40 |
| SongCompactRow | 44 (`rowHeight`) |

- `ImageLoader.loadLocal`: `NSImage(contentsOf:)` + 2× `NSBitmapImageRep` / `NSGraphicsContext` downsample, same pattern as `AlbumArtworkExtractor.dominantColors`. Still `Task.detached`, in-flight merge, no `file://` `URLSession`.

### Display-only swaps (types kept)

- `PlayerBar.artwork` is the brief snippet: `ArtworkSource.resolve` + `targetSize: 52`. `.onTapGesture { onArtworkTap() }` stays on the 52pt frame. No matched geometry.
- `GlobalSearchView` track/artist/album rows: `ArtworkView` + `localHash`, `targetSize: 40`, `glyphSize: 16`. Artist row `clipCircle: true`. Private row types kept; not converted to `SongObjectView`.
- `HomeView` hero + `RecentTrackCard` → `ArtworkView`. `updateGradientAsync` still detached (`Data(contentsOf:)` + `NSImage(data:)`).
- `AlbumCard`, `SongRow`, `ArtistCard`, `DiscoveryCard`, `SongCompactRow`, NewView situational card, Album/Artist detail headers → `ArtworkView`.
- Album/artist `extractGradient`: cancel previous task, `Task.detached` + `loadNSImage()`, apply only if identity still matches and task not cancelled. `onDisappear` cancels the task.

**Not deleted:** `AlbumCard`, `DiscoveryCard`, `RecentTrackCard`, `ArtistCard`, `SongCompactRow`.

## Done-bar grep

```
rg -n 'NSImage\(byReferencing:|NSImage\(contentsOf:|\.cached\(' Muses/Sources/Muses
```

Leftovers (all allowed):

| File | Why allowed |
|---|---|
| `ImageLoader.swift:50` | local bounded path |
| `ArtworkSource.swift:67` | `loadNSImage()` |
| `SidebarView.swift:128` | sidebar logo |
| `SettingsSheet.swift:136` | settings logo |
| `AboutView.swift:13` | about logo |

No table-file hit inside `var body`. No `.cached(`. No `byReferencing`.

## Verification

| Check | Result |
|---|---|
| App + test targets compile | PASS (15.10s) |
| `swift test --no-parallel --filter 'artworkSourceResolution\|artworkSourceLocalHash\|PhaseP4GlassTests'` | PASS — 8 tests, 3 suites (ArtworkCache 1, PhaseP3Enrichment 1, PhaseP4Glass 6) |
| Card types still present | yes |
| Local path uses URLSession | no |

## Commit

- `3adafe9` — fix: ArtworkView display path; no NSImage decode in view body

16 files, +160 / −217, `Muses/Sources/Muses` only.

## Self-review

- **Completeness:** Steps 1–6 done. Starting-set body hits gone. Explicit sizes landed. `lockFocus` gone.
- **Quality:** Decode stays in `ImageLoader` / detached helpers. Identity guards on album/artist gradients match Home/Now Playing shape.
- **Discipline:** Display-only. No engine, queue, SwiftData, or type-deletion work.
- **Testing:** Filtered Swift Testing only. No rendered screenshot of the new frames.

## Concerns

1. **Search row size 32 → 40.** Brief mandates `targetSize: 40`. Overlay rows are slightly taller/wider than before.
2. **Placeholder glyph change.** Artist card/header and search artist row used `person.2.fill`; `ArtworkView` always shows `music.note`.
3. **`DiscoveryCard.lowResURL` unused for decode.** Type API kept (`_ = (lowResURL, fallbackSymbol)`). Remote now goes through `ArtworkView` → `CachedAsyncImage` without the low-res hop. Current Home/New callers only pass local `artworkPath`.
4. **Wide `DiscoveryCard`.** Square `ArtworkView(targetSize: size)` is clipped by the existing 16:9 outer frame. Fine if no caller uses `.wide169` with a local file today.
5. **YouTube search row still `AsyncImage`.** 56×32 16:9; not an `NSImage` body decode. Brief targeted the three library `byReferencing` sites. Same for Home `YouTubeTrendingCard` / `HomeDiscoveryCardView` / import cards (`CachedAsyncImage`).
6. **No rendered visual check.** Inner/outer frames now match in source; Cover/Vinyl/Mini/Bar/search/cards were not screenshot-verified.
7. **`extractGradient` no longer uses `contentsOf` in the view file.** It calls `loadNSImage()` in `Task.detached`. Equivalent I/O, cleaner grep. Placeholder / failed load still leaves the previous gradient (same as Task 4 Now Playing).
