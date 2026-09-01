# Task 4 Report: ArtworkSource identity + ImageLoader local path

## Status

**DONE_WITH_CONCERNS**

## Summary

`ArtworkSource` is now an identity enum (`.localFile` / `.remote` / `.placeholder`). Resolve helpers no longer decode. `ArtworkView` loads via `LocalArtworkImage` (bounded `ImageLoader.loadLocal`) or `CachedAsyncImage`. `extractGradient` decodes off-main through `loadNSImage()` and ignores stale track IDs. App and test targets both compiled; the two filtered tests passed. Remaining `NSImage(byReferencing:)` body-decode sites were left for Task 5.

## Changes

### `ArtworkSource.swift`

```swift
enum ArtworkSource: Equatable, Sendable {
    case localFile(URL)
    case remote(URL)
    case placeholder
}
```

- `localHash(_:)`: empty/nil/`path(forHash:)` nil → `.placeholder`; else `.localFile(url)`.
- `resolve(for: TrackSnapshot?)` / album / artist: hash → URL → first YT thumb. No `NSImage` in resolve.
- `loadNSImage()`: blocking `NSImage(contentsOf:)` / `Data(contentsOf:)` for detached palette only.
- `ArtworkView`: `.localFile` → `LocalArtworkImage`; `.remote` → `CachedAsyncImage`; default `targetSize` 200; `AnyShape` clip.
- `LocalArtworkImage`: first frame from `cachedImage(for:targetSize:)`; miss starts `loadLocal`; cancel on disappear; drop result if url/size identity changed.

### `ImageLoader.swift`

- Size-aware `cacheKey` / `cachedImage(for:targetSize:)`.
- `loadLocal`: `NSImage(contentsOf:)` + 2× downsample via `lockFocus` in `Task.detached`. Does **not** send `file://` through `URLSession`.
- `inFlight` merge + `defer` MainActor clear, same as `load(_:)`.
- Existing `load(_:)` / `CachedAsyncImage` unchanged.

### `NowPlayingView.extractGradient()`

Detached `source.loadNSImage()`, then MainActor palette (`count: 4`) if `playback.state.track?.id` still matches. Removed unused `applyGradient`.

### Tests

- `ArtworkCacheTests.artworkSourceLocalHash`: nil/empty/missing hash → `.placeholder`.
- `PhaseP3EnrichmentTests.artworkSourceResolution`: exhaustive `.localFile` / `.remote` / `.placeholder` switches (a future `.cached` case fails to compile). Existing remote/placeholder expectations unchanged.

## Verification

| Check | Result |
|-------|--------|
| `swift test --no-parallel --filter 'artworkSourceResolution\|artworkSourceLocalHash'` | PASS — app + test targets linked (14.23s). 2 tests, 2 suites. |
| App target compile after enum change | PASS — no leftover `.cached` matchers. Body-decode cards still compile. |
| `rg 'case \.cached\|ArtworkSource\.cached'` in `*.swift` | no hits |
| Local path uses `URLSession` | no — `loadLocal` uses `NSImage(contentsOf:)` |
| AlbumCard / DiscoveryCard deleted | no |

## Commit

- `6acf58e` — fix: ArtworkSource identity and bounded ImageLoader local decode

## Self-review

- **Completeness:** Steps 1 and 3–7 done. Step 2 (expected compile fail on `.cached`) was not run as a separate red step; enum + call-site rewrite landed with the tests and compiled green.
- **Quality:** Resolve does not decode. Local files do not go through `URLSession`. Gradient I/O is detached and identity-guarded.
- **Discipline:** Five specified files only. No engine edits. No card swaps. No `AlbumCard` deletion.
- **Testing:** Filtered Swift Testing run only. No rendered screenshot of the new `ArtworkView` frame.

## Concerns

1. **Default `targetSize` 200.** `ArtworkView` now always `.frame(width:targetSize, height:targetSize)`. Existing callers still compile with the default 200 and apply their own outer frames (CoverArt 480, Vinyl ~288, MiniPlayer 180, Up Next 36, derived detail 160). Inner content will sit at 200 until Task 5/9 pass `targetSize`. Visual regression on those surfaces if the app is run now.
2. **`extractGradient` behavior change.** Palette runs on MainActor after detached decode (`count: 4`, was 3). Placeholder / failed load no longer resets `gradient` to `[background, surface]` — previous colors stay until a later success.
3. **`lockFocus` off-main.** Brief-specified downsample uses `dest.lockFocus()` inside `Task.detached`. Not officially thread-safe. Compiled and was not exercised by these unit tests.
4. **`localHash` present-hash path.** Not asserted: writing a real file into `ArtworkCache.default` would mutate the user cache. Missing-hash path is covered.
5. **Body-decode leftovers.** `PlayerBar`, `HomeView`, `LibraryView`, `AlbumDetailView`, `ArtistsView`, `ArtistDetailView`, `NewView`, `GlobalSearchView` still decode in `body` via `NSImage(byReferencing:)`. Intentional Task 5 work.
