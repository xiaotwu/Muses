# Final Fix Report: Artwork-world Important findings

## Status

**FIXED** (code). Rendered recapture still remaining.

## Summary

One fix wave on `20eb4ad` for the four Important whole-branch findings. PlayerBar keeps a 52×52 `liveCover` token with `isSource: false` while Now Playing is open (pixels hidden, effect kept). `LiveCoverHost` stays in-tree through the close morph (`liveCoverHostRetained`, opacity 0 if the slot is gone). Hover Play on Album / Artist / Hero is a sibling overlay on the card Button, not a nested Button. `LocalArtworkImage` no longer cancels the shared `ImageLoader` task. `NowPlayingMark` has `tr("Now Playing", "正在播放")` and is no longer VoiceOver-hidden on song rows.

## Changes

### 1. PlayerBar matched geometry while Now Playing is open

**Finding:** When `showNowPlaying`, the 52pt token became `Color.clear` **without** `matchedGeometryEffect`, and `LiveCoverHost` existed only while NP was open — no simultaneous pair (spec §5.5.2).

**Fix:**
- `PlayerBar.artwork`: the morph path always applies `.matchedGeometryEffect(id: .liveCover(trackID), isSource: !showNowPlaying)` to a stable 52×52 token. While NP is open the pixels are `Color.clear`; the effect is not removed.
- `RootView`: `@State liveCoverHostRetained` is set on open (when morph is not skipped) and cleared after `MusesMotion.nowPlayingMorph` on close. Host mounts when `showNowPlaying || liveCoverHostRetained`. If the cover-slot preference is already gone, the retained host stays at opacity 0.

Skip path unchanged: Reduce Motion, lyrics-fullscreen, no track, width < 960 — no MGE, PlayerBar art stays in the bar.

### 2. Hover Play nested Button

**Finding:** Album / Artist / Hero wrapped `HoverPlayButton` (a `Button`) inside the card `Button`, so Play vs click-to-open fought.

**Fix:** Move the overlay **onto** the card Button (after `.buttonStyle(.plain)`), not inside the label.
- Album: sibling overlay aligned to the artwork square, Play at `.bottomTrailing`.
- Artist: sibling overlay on the circle, Play at `.bottom`.
- Hero: sibling overlay `.bottomTrailing` on the artwork Button.

Song rows unchanged: they are not wrapping Buttons (`onTapGesture` + overlay Play).

### 3. LocalArtworkImage cancelled shared decode

**Finding:** `.onDisappear` cancelled `ImageLoader.shared.loadLocal`’s in-flight `Task`. Scrolling one cell offscreen aborted decode for every other waiter on the same key.

**Fix:** Match `CachedAsyncImage`. Await the shared task, ignore the result if identity changed or the view `.task` was cancelled. Do not `cancel()` the loader task.

### 4. NowPlayingMark VoiceOver

**Finding:** The mark had no accessibility name. Song rows hid it (`.accessibilityHidden(true)`), so VoiceOver had no “Now Playing” name.

**Fix:** `NowPlayingMark` gets `.accessibilityLabel(tr("Now Playing", "正在播放"))`. Song rows no longer hide `NowPlayingMark`. The fallback speaker glyph (only when `nowPlayingID` is nil) stays hidden.

## Files

- `Muses/Sources/Muses/Features/PlayerBar.swift`
- `Muses/Sources/Muses/App/RootView.swift`
- `Muses/Sources/Muses/Features/Shared/AlbumObject.swift`
- `Muses/Sources/Muses/Features/Shared/ArtistObject.swift`
- `Muses/Sources/Muses/Features/Shared/HeroObject.swift`
- `Muses/Sources/Muses/Features/NowPlaying/ArtworkSource.swift`
- `Muses/Sources/Muses/Features/Shared/NowPlayingMark.swift`
- `Muses/Sources/Muses/Features/Shared/SongObject.swift`

## Out of scope (this wave)

- Card → detail matched geometry
- Glass on cards
- Engine / SwiftData / yt-dlp
- Full Task 10 recapture against a real library
- Reduce Motion / Reduce Transparency recapture

## Verification

| Check | Result |
|---|---|
| `swift test --no-parallel` | PASS — 408 tests, 70 suites, 14.417s |
| PlayerBar 52pt token keeps `liveCover` MGE while NP open | code |
| Host retained through close morph | code (`liveCoverHostRetained` + opacity 0 fallback) |
| Album/Artist/Hero Hover Play not nested in card Button | code |
| Song Hover Play still overlay on non-Button row | unchanged |
| `LocalArtworkImage` does not cancel shared `loadLocal` | code |
| `NowPlayingMark` VoiceOver label | `tr("Now Playing", "正在播放")` |
| Song-row mark not `accessibilityHidden` | code |
| Rendered morph / hover Play / VO | **not recaptured** (empty-store environment limit) |

## Commit

- `c05ff36` — fix: keep live-cover pair, sibling Hover Play, shared decode, VO mark

## Remaining concerns

1. **Task 10 recapture against a real library is still remaining.** The in-memory session / corrupt-store fallback empties the library, so Hero, rails, hover Play, morph interpolation, and vinyl crossfade cannot be click-tested. Environment limit, not this wave.
2. **Reduce Motion / Reduce Transparency recapture** was explicitly deferred this wave. Skip-morph and no-lift paths are still code-only.
3. **Close-morph host keep-alive is timed**, not animation-completion-driven. After `nowPlayingMorph` (0.32s) the host is dropped. If the slot preference is gone mid-animation, the host is opacity 0 rather than interpolating from the 480pt slot. Reverse morph is now possible (pair exists) but not visually proven.
4. **Song-row fallback speaker** (`isNowPlaying` without `nowPlayingID`) remains `.accessibilityHidden(true)`. Call sites pass `nowPlayingID`; only that path is labeled.
5. **Hover Play overlay hit-testing** relies on the 30pt control (plus padding) not expanding via `contentShape`. Not click-tested in this empty session.
