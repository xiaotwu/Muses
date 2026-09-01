# Task 2 Report: Play-context correctness

## Status

**DONE**

## Summary

Recently Played, playlist in-row Play, and YouTube-import in-row Play now pass the **visible list** as `playTrack` context, not `[snap]`. Service-layer tests were written first as contract locks and passed before any view edit. No `PlaybackService` internals, no playlist row tap-to-play, no Search/Escape/Retry work.

## TDD evidence

### RED/GREEN

These tests lock the existing `QueueService.play` / `PlaybackService.playTrack` contract. They were **expected to PASS before view edits** (plan-mandated contract-lock, not classic RED on the view bug).

| Step | Filter | Result |
|------|--------|--------|
| 3a | `QueueServiceTests.recentlyPlayedFullContext` | **PASS** (0.001s) — before view edits |
| 3b | `QueueServiceTests.playlistFullContext` | **PASS** (0.001s) — before view edits |
| 3c | `PlaybackServiceTests.recentlyPlayedNextAdvances` | **PASS** (0.285s) — before view edits |

Recorded as **GREEN contract-lock**. They do not prove the view call sites; grep does.

### View call-site proof (grep done-bar)

```
rg -n 'context: \[snap\]' Muses/Sources/Muses
```

**Forbidden sites (must be gone):**

| Site | Status |
|------|--------|
| `HomeView` Recently Played | Gone. Now `context: recentlyPlayed` |
| `PlaylistTrackRow` in-row Play | Gone. Play button calls parent `onPlay` → `playFromList(item)` |
| `YouTubeImportItemRow` in-row Play | Gone. Now `context: context` (parent passes `visibleSnaps`) |

**Allowed remaining `context: [snap]`:**

| File | Line | Why allowed |
|------|------|-------------|
| `YouTubeSearchView.swift` | 112 | discovery/search `importAsTrack` |
| `HomeView.swift` | 328, 425 | discovery/search `importAsTrack` |
| `GlobalSearchView.swift` | 245 | Search (Task 3) |
| `History/HistoryView.swift` | 227 | History |
| `Inbox/InboxView.swift` | 164 | Inbox |
| `App/MusesApp.swift` | 344 | one-shot/deep-link |
| `NewView.swift` | 94 | situational until Task 7 |

Queue history Replay: no `context: [snap]` hit under `Features/Queue`.

## Changes

### Tests (append only)

- `QueueServiceTests.swift`: `recentlyPlayedFullContext`, `playlistFullContext` — full list, tapped index, `next()` advances.
- `PlaybackServiceTests.swift`: `recentlyPlayedNextAdvances` — `playTrack(b, context: [a,b,c], from: .recently)` then `next()` → `"c"`.

### Views

**`HomeView.swift` Recently Played**

```swift
playback.playTrack(snap, context: recentlyPlayed, from: .recently)
```

**`PlaylistDetailView.swift`**

- `PlaylistTrackRow` gained `var onPlay: () -> Void`.
- ForEach wires `onPlay: { playFromList(item) }`.
- In-row Play is `Button(action: onPlay)`. Unused `PlaybackService` environment removed from the row.
- No `.onTapGesture { play(...) }` on the playlist row.

**`YouTubeImportsView.swift`**

- `YouTubeImportItemRow` gained `let context: [TrackSnapshot]`.
- Parent passes `visibleSnaps` = import YT items (`items.compactMap { $0.track }.map { TrackSnapshot(from: $0) }`), same array as this card’s Play All.
- In-row Play: `playback.playTrack(snap, context: context, from: .import)`.

## Verification

| Check | Result |
|-------|--------|
| Contract-lock tests before view edits | 3/3 PASS |
| Covering `swift test --no-parallel --filter 'QueueServiceTests\|PlaybackServiceTests'` | 13 tests / 2 suites PASS |
| Full `swift test --no-parallel` | 407 tests / 70 suites PASS |
| Grep done-bar | Forbidden three gone; allow-list intact |
| No playlist row tap-to-play | Confirmed (`onTapGesture` only in `AddToPlaylistSheet` picker) |
| PlaybackService internals / Search-Escape-Retry / NewView | Untouched |

## Commit

- `eeaf0ab` — fix: play recently played and playlist/import rows with full list context

## Self-review

- **Completeness:** All six brief steps done (tests, GREEN contract-lock, three call sites, grep, covering + full suite, commit).
- **Quality:** Call sites pass the visible list; playlist Play reuses existing `playFromList`; import row uses the same snaps as Play All on that card.
- **Discipline:** Five files only. No engine rewrite. No playlist tap-to-play. NewView `[snap]` left for Task 7.
- **Testing:** Service tests GREEN before views; covering 13/13; full suite green.

## Concerns

None. Import in-row context is the expanded YT item list (this card’s Play All), not `YouTubeAlbumDetailView.allSnaps` (YT + local additions). Local-addition rows in the expanded card still have no Play button.
