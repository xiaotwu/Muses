# Task 10 Report: Home/New polish and rendered QA

## Status

**DONE_WITH_CONCERNS**

## Summary

Rail card titles on 160pt Album objects and Home 16:9 discovery cards use `.subheadline` / `.caption` (spec §5.8). Home/New section titles stay on `SectionHeader`. Hero is unchanged. Rendered QA ran in the packaged worktree app: Search overlay, ⌘F, Escape-on-Search, rail Retry, light Home, and wide/narrow Now Playing skip-path were captured. `swift test --no-parallel`: **408 tests / 70 suites passed**. Hero, hover Play, album/artist detail, Songs selection, morph interpolation, vinyl crossfade, Queue Escape, and Reduce Motion / Reduce Transparency were not proven (empty in-memory session + accessibility defaults did not apply).

## Changes

### Type scale (Step 1)

`AlbumObjectView` title/subtitle cutoff moved from `size >= 200` to `size >= 160`:

- title `.subheadline` (was `.caption` on 160pt rails)
- subtitle `.caption` (was always `.caption2`)

`HomeView` 16:9 cards (`YouTubeTrendingCard`, `HomeDiscoveryCardView`) match: title `.subheadline`, uploader `.caption`.

`NewView` already uses `SectionHeader` + `AlbumObjectView` at `MusicObjectMetrics.albumRail` (160). No NewView edit. Hero stays the Media Environment (no Now Playing theatrics).

### QA catalog (Step 2)

Created `artifacts/artwork-world-qa-2026-08-18/` with window captures and `screenshot-catalog.md`. See that file for the required table and blockers.

## Not done (blocked, not out of scope)

These were attempted in the running app:

- Hero + hover Play on 160pt rails
- 200pt Album grid, 240pt album-detail hero, 180pt artist circle
- Songs durable selection / double-click-play
- PlayerBar → NP morph interpolation and vinyl host crossfade
- Queue Escape dismiss
- Reduce Motion (no morph / no lift) and Reduce Transparency

## Verification

| Check | Result |
|---|---|
| `rg -n 'context: \[snap\]' Muses/Sources/Muses` | 7 hits, allow-list only (Home discovery/trending, GlobalSearch, YouTubeSearch, History, Inbox, MusesApp) |
| `rg -n 'NSImage\(byReferencing:' Muses/Sources/Muses/Features` | no hits |
| `swift test --no-parallel` | PASS — 408 tests, 70 suites, 14.495s |
| `make app` | PASS — `build/Muses.app` ad-hoc signed |
| Type cutoff `size >= 160` | Album object + Home 16:9 cards |
| New product behavior | none |
| Engines / Liquid Glass parent files | untouched |

## Commit

- `eabe35b` — feat: artwork-world polish and rendered QA

Files: `AlbumObject.swift`, `HomeView.swift`, `artifacts/artwork-world-qa-2026-08-18/`. `NewView.swift` unchanged.

## Self-review

- **Completeness:** Step 1 type scale done. Step 2 catalog written with captured + blocked rows. Step 3 greps + full suite green. Step 4 commit as specified (plus AlbumObject, required for the §5.8 bump).
- **Quality:** Type bump is the spec cutoff; Hero and SectionHeader left alone. Catalog is judged from rendered PNGs, not source.
- **Discipline:** No engine, schema, or morph rewrite. No parent-checkout Liquid Glass files.
- **Testing:** Full suite green. Visual work is the catalog.

## Concerns

1. **Corrupt-store fallback emptied the session.** Launch wrote `muses-corrupt-2026-08-19T05-46-02Z.sqlite` and showed an empty library. On-disk `muses.sqlite` still has five YouTube tracks + one import. Hero, rails, album/artist detail, Songs selection, hover Play, morph, and vinyl could not be exercised. Not a Task 10 code change.
2. **Queue Escape did not dismiss.** `onExitCommand` is wired on `QueueDrawerView`. System Events Escape left the drawer up. Scrim click and AX Close dismissed it. Search Escape with a focused non-empty query **did** dismiss.
3. **Morph interpolation unverified.** No `track?.id` → `skipArtworkMorph`. Wide NP (10) and narrow 940pt NP (11) show the skip/in-tree cover path only.
4. **Reduce Motion / Reduce Transparency not captured.** `defaults write com.apple.universalaccess` did not change rendering. System Settings was not opened.
5. **`CGEvent` Escape did not reach SwiftUI.** System Events keystrokes did. Click-tests that used the raw event source were re-run.
6. **`CoverSlotPreferenceKey.defaultValue` / host landing** (Task 9) still unverified — no live morph.

---

## Fix report — Queue Escape

**Finding:** Queue Escape did not dismiss in rendered QA. `QueueDrawerView` only had `.onExitCommand` on the root `HStack`. Search dismissed because its focused field also has `.onExitCommand` / `.onKeyPress(.escape)`. The rename-group alert must keep Escape.

**Change:** On the root container (not the rename `alert`):

- `.onKeyPress(.escape)` dismisses when `renameTarget == nil`, else `.ignored`
- `.onExitCommand` uses the same guard
- `.focusable()` + `@FocusState drawerFocused` (same pattern as `NowPlayingView` space handling / Search field focus) so the drawer receives keys without a text field
- `onAppear` focuses the drawer; `onChange(of: renameTarget)` returns focus after the alert closes

**Not done:** No morph/hero recapture. Rename-alert Escape not click-tested (no groups in the empty session).

**Verification:**

- `swift test --no-parallel` — 408 tests / 70 suites passed (14.844s)
- Rendered retest: PlayerBar list opened Queue (`09-queue-escape-retest-open.png`); System Events Escape dismissed it (`09-queue-escape.png` / `09-queue-escape-retest.png`). AX `Queue` heading gone after Escape.

**Commit:** `20eb4ad` — fix: dismiss Queue on Escape when rename alert is closed
