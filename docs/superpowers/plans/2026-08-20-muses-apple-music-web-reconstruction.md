# Muses Apple Music Web reconstruction — implementation plan

- **Date:** 2026-08-20
- **Status:** Complete on the available 1280×800 desktop; the host display cannot produce a literal 1440×900 app capture
- **Specification:** `docs/superpowers/specs/2026-08-20-muses-apple-music-web-reconstruction.md`
- **Stack:** Swift 6, SwiftUI, AppKit bridge at the window boundary, SwiftData, Swift Testing

## Working rules

- Preserve the existing dirty worktree; do not reset or overwrite unrelated changes.
- Use small, reviewable patches and verify after every phase.
- Follow the approved D1 logical-snapshot cutover; never delete the legacy physical store as part of activation.
- Restore Albums, Artists, and Music Videos only through the approved D2 stable-identity model.
- Use the approved D3 collection composition for Songs and every playlist detail.
- Keep playback, queue, history, and import behavior stable while changing presentation.
- User-visible strings use `tr` and new source identifiers/comments are English.
- Visual acceptance requires the rendered `.app`, not policy tests alone.

## Baseline

- [x] Audit source, tests, runtime, historical specs, and current dirty worktree.
- [x] Inspect live Apple Music Web Home, New, Songs, Search, playlists, detail, and Up Next.
- [x] Measure the 1440×900 baseline tokens.
- [x] Run focused Chrome tests.
- [x] Run the full suite and record three stable pre-existing failures.
- [x] Confirm product and visual decisions with the user.

## Phase 0 — Contract and decision safety

### Task 0.1 — Establish the authority chain

- [x] Add the approved reconstruction specification.
- [x] Update `AGENTS.md` to cite the new specification and current user decisions.
- [x] Mark the old Apple Music visual draft as superseded.
- [x] Keep historical plans as history rather than treating unchecked boxes as work.

### Task 0.2 — Record approved decisions

- [x] D1: one-time logical snapshot/import into a clean V3 store; preserve the old store for rollback.
- [x] D2: ID-backed Releases and Artists plus Track media-kind Music Videos; Radio remains absent.
- [x] D3: shared collection identity/actions + all-track horizontal hero rail + complete sortable table.
- [x] Songs canonical/default order is title A–Z with no manual ordering.

## Phase 1 — Native window and stable traffic lights

### Task 1.1 — Add policy coverage

Files:

- `Muses/Sources/Muses/App/AppleMusicTokens.swift`
- `Muses/Tests/MusesTests/ChromeLayoutTests.swift`

- [x] Add an explicit policy that standard window buttons remain native-owned.
- [x] Tokenize one traffic-light clearance used by expanded and collapsed sidebars.
- [x] Add minimum-window and sidebar geometry policies.
- [x] Run `swift test --no-parallel --filter ChromeLayoutTests` and confirm the new tests fail before implementation.

### Task 1.2 — Replace reparenting with one AppKit boundary

Files:

- `Muses/Sources/Muses/Features/Shared/TrafficLightsPad.swift`
- `Muses/Sources/Muses/App/MusesSingleInstance.swift`
- `Muses/Sources/Muses/App/RootView.swift`
- `Muses/Sources/Muses/Features/SidebarView.swift`

- [x] Replace the AppKit traffic-light host with a transparent SwiftUI clearance.
- [x] Add one idempotent main-window configurator.
- [x] Keep `standardWindowButton` instances in their native AppKit hierarchy.
- [x] Remove delayed toolbar retries and recursive sidebar-button scans.
- [x] Use identical clearance geometry in expanded and collapsed sidebars.
- [x] Preserve activation, frame autosave, titlebar transparency, full-size content, and window dragging.

### Task 1.3 — Verify the real window

- [x] Build and launch the SwiftPM GUI as a `.app` bundle.
- [x] Inspect expanded and collapsed sidebars at the host maximum 1280×800 and minimum 840×600; retain the measured 1440×900 live-Web baseline for token comparison.
- [x] Move, resize, minimize, restore, zoom, switch routes, open Settings, and open/close Now Playing.
- [x] Confirm native traffic lights never move relative to the window and remain clickable.
- [x] Capture before/after screenshots.

## Phase 2 — Semantic tokens and surfaces

Files:

- `Muses/Sources/Muses/App/AppleMusicTokens.swift`
- `Muses/Sources/Muses/App/GlassSurface.swift`
- `Muses/Sources/Muses/App/RootView.swift`
- shared chrome components

- [x] Separate measured ideal values from responsive minimums and breakpoints.
- [x] Add semantic spacing roles for page, section, shelf, table, and chrome.
- [x] Restore subtle visible hairlines.
- [x] Centralize sidebar, PlayerBar, Settings, and compact-control glass roles.
- [x] Audit native glass grouping; the current chrome surfaces are spatially independent and do not require a shared `GlassEffectContainer`.
- [x] Verify material and opaque accessibility fallbacks with focused policy tests.
- [x] Remove unused Sidra glow helpers after all call sites are migrated.

## Phase 3 — Responsive shell and sidebar

- [x] Make 244pt expanded and 88pt collapsed sidebar geometry deterministic.
- [x] Align wordmark, nav rows, section labels, playlist rows, and profile to one baseline grid.
- [x] Preserve full-row pointer targets, keyboard focus, and localized accessibility labels.
- [x] Remove hidden obsolete destinations from route fallbacks.
- [x] Define responsive main-content insets and prevent fixed-card clipping.
- [x] Verify sidebar selection, collapse, restoration, and route transitions through policy tests and the earlier unlocked runtime pass.

## Phase 4 — PlayerBar, Queue, Settings, and Now Playing

### PlayerBar

- [x] Preserve the 668×56 ideal capsule while defining constrained-width layouts.
- [x] Establish control priority and avoid duplicate volume controls.
- [x] Use `YouTubeMark` for YouTube video.
- [x] Keep scroll-bottom insets synchronized with visible chrome.

### Queue

- [x] Replace the floating drawer with an integrated full-height trailing pane.
- [x] Preserve current queue, Up Next, history, repeat, shuffle, reorder, and persistence semantics.
- [x] Verify Queue/Now Playing mutual exclusion.

### Settings

- [x] Keep a centered 520×560 native glass panel.
- [x] Remove artwork color bleed and improve group/title contrast.
- [x] Verify Escape, scrim dismissal, and the neutral surface contrast in the rendered app.
- [x] Verify high-contrast and Reduce Transparency surface decisions with focused policy tests without changing system-wide accessibility preferences.

### Now Playing

- [x] Disable Now Playing and lyrics entry without a current track.
- [x] Preserve cover/vinyl modes and two-column lyrics at roomy widths.
- [x] Add constrained-width adaptation.
- [x] Make lyrics scrolling and vinyl motion respect Reduce Motion.

## Phase 5 — Page-specific reconstruction

### Collection composition (approved D3)

- [x] Add immutable collection-row values containing canonical order and complete display metadata.
- [x] Add a shared responsive identity/actions + horizontal all-song hero rail.
- [x] Add a native sortable/customizable table with keyboard, pointer, context-menu, and accessibility behavior.
- [x] Use title A–Z as Songs canonical/default order.
- [x] Use `PlaylistItem.order` and `YouTubeImportItem.order` as playlist canonical/default order.
- [x] Keep table sorting visual-only and preserve canonical playback context.
- [x] Apply the shared composition to Songs, user playlists, and YouTube imports.

### Other independent work

- [x] Rebuild Search around a centered field, scope control, categories, and grouped results.
- [x] Rebuild Recently from playable YouTube-backed snapshots.
- [x] Neutralize History's competing blue/cyan visual system while preserving its data.
- [x] Keep Playlists overview as square artwork cards with corrected spacing.

### Home and New

- [x] Implement Home portrait Top Picks and square shelves around the measured Apple Music Web hero.
- [x] Implement New landscape editorial cards and compact song matrices around the measured Apple Music Web hero.

### Catalog destinations (approved D2)

- [x] Add stable-ID Release and Artist catalog models/projections.
- [x] Add a Track media kind and Music Videos destination.
- [x] Restore Albums and Artists destinations without name-only identity merging.
- [x] Define refresh, stale-cache, loading, empty, unavailable, and collection-playback states.

## Phase 6 — Retire running local-era behavior and cut over persistence

- [x] Remove `LocalAudioEngine` from the production composition root.
- [x] Remove folder/file import, scanner, M3U, and Add Local entry points.
- [x] Remove local additions to imported YouTube playlists.
- [x] Remove local-only search and Recently fallbacks from visible routes.
- [x] Update tests that directly encode the retired local engine path.
- [x] Export user truth from the legacy store to a versioned logical snapshot.
- [x] Import into and validate a distinct clean V3 store.
- [x] Activate V3 only after counts, IDs, required YouTube IDs, relationships, and item order pass validation.
- [x] Preserve the legacy store unchanged as a rollback source.

## Phase 7 — Accessibility, motion, and performance

- [x] Audit every icon-only control for localized label, help, and selected/value state.
- [x] Verify native keyboard focus reaches the Songs table and that standard SwiftUI/AppKit focus effects are not suppressed.
- [x] Replace refresh-count vinyl rotation with elapsed-time rotation.
- [x] Stop hidden Timeline/spectrum work.
- [x] Apply Reduce Motion to lyric scrolling and all new transitions.
- [x] Verify Reduce Transparency and increased-contrast surface fallback decisions with focused tests.
- [x] Confirm large lists use snapshots and lazy containers.
- [x] Make no unprofiled performance claims; changes are limited to eliminating unnecessary clocks and stale work.

## Phase 8 — Test repair and final acceptance

- [x] Repair or replace the stale `NowPlayingManagerTests` engine seam.
- [x] Define and test session-resume duration clamping.
- [x] Make the V3 immutability test use an unopened legacy fixture so delayed SQLite checkpoints cannot create a false migration failure.
- [x] Run the complete Swift test suite: 505 tests in 77 suites pass.
- [x] Build, sign, and launch `build/Muses.app` through the project run entrypoint.
- [x] Capture the final rendered app at 1280×800 and 840×600; 1440×900 is unavailable on the 1280×800 physical display.
- [x] Inspect dark and light appearances in the rendered app; verify high contrast, Reduce Transparency, and Reduce Motion decision paths with focused tests.
- [x] Compare Home, New, Search, Songs, playlist detail, Albums, Artists, Music Videos, History, Playlists, Queue, Settings, and Now Playing against the measured live Apple Music Web reference.
- [x] Perform playback, queue, search, Settings/Escape, Now Playing, sidebar collapse, resize, restoration, and accessibility-tree smoke tests; preserve import and context-menu semantics through the full regression suite and native controls.

Rendered acceptance is complete at every size the current host can display. The
physical screen is 1280×800, so a literal 1440×900 app screenshot is impossible
without synthetic scaling. Dark and light appearances were rendered directly;
accessibility appearance fallbacks were verified without mutating the user's
system-wide accessibility preferences.

## Decision log follow-up

- [x] D1 approved: clean V3 logical cutover, no legacy deletion during activation.
- [x] D2 approved: stable-ID Releases/Artists and Track-kind Music Videos; no Radio.
- [x] D3 approved: collection hero rail plus full sortable table; Songs defaults A–Z.
