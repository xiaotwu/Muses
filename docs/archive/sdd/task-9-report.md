# Task 9 Report: PlayerBar ↔ Now Playing artwork morph

## Status

**DONE_WITH_CONCERNS**

## Summary

PlayerBar 52pt art and Now Playing 480pt cover are one live token under a RootView `@Namespace`. Three NP overlays (environment gradient/scrim, chrome, live-cover host) replace the whole-view opacity fade. The host owns `CoverArtModeView` / `VinylModeView` and sits above chrome. Morph skips on Reduce Motion, lyrics-fullscreen, no track, or width < 960pt. `swift test --no-parallel`: **408 tests / 70 suites passed**. Rendered morph not click-tested (same AX / Screen Recording block as Tasks 3 and 8); defer to Task 10.

## Changes

### Created

- `ArtworkContinuity.swift` — `ArtworkContinuityID` (liveCover + reserved unused cases), `ArtworkWorldNamespaceKey` / `.artworkWorldNamespace`, `CoverSlotPreferenceKey` (`static let defaultValue` for Swift 6), `NowPlayingEnvironmentLayer`, `LiveCoverHost`.

### RootView

- `@Namespace artworkWorld` injected as `.environment(\.artworkWorldNamespace, artworkWorld)`.
- `@State coverSlot` kept; `Anchor` is not Equatable so positioning uses `overlayPreferenceValue` (binder only syncs nil-ness).
- **Back:** `NowPlayingEnvironmentLayer` (gradient extract moved here) + `.transition(.opacity)`.
- **Middle:** `NowPlayingView` chrome only, `.transition(.opacity)`. No whole-view fade wrapping the cover.
- **Front:** slot-sized `LiveCoverHost`, no insertion opacity transition. MGE on **still** `CoverArtModeView` only (`isSource: showNowPlaying`).
- Skip: `accessibilityReduceMotion` || lyricsFullscreen || no `track?.id` || `windowWidth < 960`.
- PlayerBar gets `showNowPlaying` / `skipArtworkMorph` parameters (no new service).
- Body split (`splitView` / `detailStack` / `continuityChrome`) so the type checker can finish.

### PlayerBar

- Morph path: MGE `id: .liveCover(trackID)`, `isSource: !showNowPlaying`.
- Active morph: 52×52 `Color.clear` placeholder (bar does not collapse).
- Skip: art stays in place, no MGE. `ArtworkView` targetSize 52 unchanged.

### NowPlayingView

- Gradient/scrim paint removed (wide displayed gradient is the RootView environment overlay).
- Wide + morph: `centerContent` is `Color.clear` 480×480 + `CoverSlotPreferenceKey` anchor. No Cover/Vinyl inside this view.
- Narrow or skip: today’s `CoverArtModeView` / `VinylModeView` in `singleColumnLayout` ScrollView (and two-column left column when skip is Reduce Motion / no track).
- `showLyrics` lifted to RootView as `Binding` so skip-at-open sees lyrics-fullscreen without a first-frame race.

### Vinyl

- Host morphs still 480pt `CoverArtModeView`. After `MusesMotion.nowPlayingMorph` (0.32s), host crossfades to `VinylModeView` (`MusesMotion.overlay`).
- MGE is not on the rotating disc. On dismiss, still cover opacity returns so reverse morph is not the disc.
- Vinyl rotation math, `PlaybackService`, `NowPlayingManager`, spectrum: **untouched**.

## Not done (out of scope)

- Card → detail matched geometry (reserved IDs unused).
- Engine / `PlaybackService` / `NowPlayingManager` / vinyl math / spectrum edits.
- Rendered morph screenshots (Task 10).

## Verification

| Check | Result |
|---|---|
| `swift test --no-parallel` | PASS — 408 tests, 70 suites, 14.818s |
| Whole-view NP `.transition(.opacity)` wrapping cover | removed; chrome and environment fade as siblings of the host |
| Wide path Cover/Vinyl inside `NowPlayingView` | no; slot + host |
| MGE on vinyl disc | no |
| Skip < 960 / Reduce Motion / lyricsFullscreen / no track | code-wired |
| Card → detail MGE | not implemented |
| Rendered tap morph / chevron back / resize / Reduce Motion / lyrics-fullscreen / vinyl crossfade | **not run** |

## Commit

- `f605388` — feat: PlayerBar to Now Playing artwork morph

5 files, +342 / −136: `ArtworkContinuity.swift` (new), `RootView.swift`, `PlayerBar.swift`, `NowPlayingView.swift`, `CoverArtModeView.swift` (comment).

## Self-review

- **Completeness:** Steps 1–4 and 6 done. Step 5 tests green; rendered matrix deferred.
- **Quality:** Host is slot-sized above chrome; gradient is behind everything; skip keeps in-tree cover; vinyl waits for settle.
- **Discipline:** No engine, schema, or card→detail work. No `musesGlass(role:)`.
- **Testing:** Full suite green. Morph is visual; unit tests cannot prove interpolation.

## Concerns

1. **No rendered smoke.** Wide morph, chevron reverse, Reduce Motion, width < 960 in-scroll cover, lyrics-fullscreen host hide, and vinyl still-cover→disc crossfade were not click-tested in the running app (same AX / Screen Recording block as Tasks 3 and 8). Defer to Task 10.
2. **`CoverSlotPreferenceKey.defaultValue` is `let`, not the brief’s `var`.** Swift 6 rejects `static var` as mutable global state. Same for `RootWindowWidthKey`.
3. **Storing `Anchor<CGRect>` in `@State` is not live-usable** (`Anchor` is not Equatable; stored anchors are only valid in the preference callback). Positioning uses `overlayPreferenceValue` + inner `GeometryReader` + offset. `coverSlot` is synced on nil-ness only.
4. **Host MGE + parent offset.** Destination frame is the 480pt slot via preference offset. If SwiftUI records MGE before offset, the morph could land at (0,0) instead of the left-column slot. Needs rendered confirmation.
5. **Always-on NP `GeometryReader` overlay** uses `allowsHitTesting(showNowPlaying)` so closed NP does not eat clicks. If a SwiftUI version still intercepts hover through that overlay, browsing hover Play would regress.
6. **Chrome still uses `.transition(.opacity)`** on `NowPlayingView` itself. That view is chrome-only on the morph path (no cover, no gradient). The forbidden whole-view fade included the cover; the host is a sibling without that transition.
7. **First layout frame:** slot preference is published after chrome lays out. One-frame missing host is possible before the cover appears at 480pt.
8. **Lyrics-fullscreen toggle while NP is open** hides/shows the host without animating `showNowPlaying`. PlayerBar swaps placeholder ↔ art without a dedicated `withAnimation(nil)` transaction; should be instant because skip is not the animated value.
