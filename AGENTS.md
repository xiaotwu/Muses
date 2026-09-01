# Muses Project Guidance

## Purpose and Scope

This file defines durable product, engineering, UX, design, performance, and verification rules for all work in this repository. It is persistent agent context, not a roadmap or task list.

Muses is a native macOS **YouTube-native music application**. The library is imported YouTube videos and playlists. Playback, queue, artwork-led browsing, a persistent PlayerBar, immersive Now Playing (video + vinyl), and native macOS integration remain the product. It is not a local-file media player and not a demo.

As of 2026-08-20 the local-file era is retired: no folder scanning, no file import, no M3U workflow, no local additions to imported YouTube playlists, and no `LocalAudioEngine` in the running app. D1 in `docs/superpowers/specs/2026-08-20-muses-apple-music-web-reconstruction.md` approves a one-time logical snapshot/import into a clean V3 store. Build and validate the replacement store at a distinct URL. Do not delete a source store as part of pointer activation; after manifest-complete validation and a successful cold restart without the pre-V3 store, remove the legacy store family and its compatibility pipeline. The user explicitly chose no long-term migration capsule on 2026-08-24.

## Source of Truth

Use this hierarchy when sources disagree:

1. Explicit current user decisions and an approved task specification.
2. Current executable source.
3. Current behavior verified at runtime.
4. Current tests.
5. Historical documentation and plans.

The approved reconstruction source is `docs/superpowers/specs/2026-08-20-muses-apple-music-web-reconstruction.md`. Tests that encode a superseded visual or product contract must be updated; they do not override that specification. Historical plans describe intent, not an active roadmap. Investigate uncertainty; do not guess. Distinguish confirmed facts, evidence-backed implications, and speculation.

## Core Architecture

### Composition

- Keep `MusesApp` as the composition root.
- Preserve stable app-lifetime identities for core services.
- Inject shared services through the existing environment boundaries; do not instantiate parallel library, playback, queue, search, import, or persistence services inside views.
- Keep view-local presentation state near its owning surface unless a demonstrated cross-feature need requires otherwise.

### Playback and Queue

- `PlaybackService` is the UI- and system-facing playback facade. Views, commands, and system integrations must not manipulate engines independently.
- Primary engine: `YouTubeStreamEngine` (yt-dlp → stream URL → `AVPlayer` immediate start, then cached file / `AVAudioEngine` when the download finishes).
- Persist downloaded media under `~/Library/Caches/Muses/streams` keyed by `videoId` + quality. Changing quality in Settings re-downloads the current track.
- Official YouTube IFrame is **not** the playback engine. Do not host a WKWebView as the sound source.
- Now Playing cover mode shows artwork (square). Vinyl mode shows circular artwork. Do not leave an empty 16:9 video slot.
- Preserve collection-context playback: playing from a playlist, search result set, recent list, or YouTube import must retain meaningful previous/next context.
- Preserve the conceptual distinction between the current collection queue, explicit Up Next insertions, and history.
- Treat repeat, shuffle, previous/next, completion, queue markers, history recording, and queue persistence as one behavioral system.
- `track.youTubeId == nil` is not a playable library item in production.

### Data and Concurrency

- Keep SwiftData model objects on their intended actor/context boundaries. Do not pass them into detached tasks or other real-time work.
- Preserve immutable `Sendable` value boundaries such as `TrackSnapshot` for playback, queueing, and detached computation.
- Continue the established fresh-context, UUID re-fetch pattern when mutating persisted objects unless an explicitly scoped architectural change replaces it.
- Persisted user truth—stable IDs, likes, playlists and item order, YouTube imports, history, queue state, notes/bookmarks, pins, and user metadata—must survive the approved D1 logical cutover.
- Do not carry retired local rows, `ScanRoot`, scanner/M3U state, or rebuildable catalog caches into the clean store. Preserve the source during cutover validation, then delete the pre-V3 store family and old-schema compatibility code after the approved cleanup gate passes.
- Releases and artists require stable YouTube Music browse/playlist or YouTube channel IDs; never merge catalog objects by display name alone. Music Videos are a `Track` media kind, not a parallel playable entity.
- Keep expensive network, metadata, palette, and recommendation work out of SwiftUI `body`.
- Large playlist screens must use lazy stacks and snapshot values. Do not eager-`VStack` hundreds of SwiftData relationships.

### Media Sources

- The unified `Track` row remains and production rows are YouTube-backed (`youTubeId` set). The clean active store and normal runtime contain no retained local rows or local-file read path.
- YouTube playlist import creates `YouTubeImport` + `YouTubeImportItem` + lazy `.youtube` Track. Local additions to YouTube playlists are removed as a product feature.
- Preserve explicit deletion semantics: deleting an import and deleting its associated tracks are different operations.
- yt-dlp remains the stream-resolution path for `YouTubeStreamEngine` and the metadata source for playlist import and fallback search. Do not describe the official IFrame player as the production audio path.
- Treat cookie settings, timeouts, signing, and personal-use distribution constraints as part of the product boundary.

## Product Contracts

Chrome (as of `docs/superpowers/specs/2026-08-20-muses-apple-music-web-reconstruction.md`; supersedes the old Apple Music draft and Sidra black/white/glow):

- Left nav (live Apple Music Web): liquid-glass rounded pane behind native `NSWindow` traffic lights, Muses wordmark, Search / Home / New (selected item is pink), then Library (Recently, Songs, History) and playlists. Standard window buttons remain AppKit-owned and are never reparented or manually positioned. Inbox is not a chrome destination. Collapse is an 88pt icon rail that reserves the same traffic-light clearance. Profile at the bottom opens Settings. No top-bar tabs. No Radio.
- Library pane is always visible unless the user collapsed it.
- Player is a floating glass capsule overlaid on browsing content (it does not reserve a layout row). Idle: Muses mark + Not Playing. Playing: art + title + times + volume. Transport left; lyrics / queue / volume / expand / YouTube last on the right as chrome glyphs. Hidden under the YouTube video overlay and while Now Playing is open.
- Queue is an integrated full-height trailing pane, not a detached floating glass drawer. Settings is a centered native floating glass panel, not an Account page inside browse content.
- Now Playing is a fullscreen overlay. Cover left with title, like, more, artist, album, seek, transport, volume; lyrics right with options. Current lyric uses accent. Chevron back closes it. Opening Now Playing closes the queue panel and hides the dock.
- Visual language matches Apple Music Web: SF Pro, near-black / near-white neutrals, accent `#FA586A` (calibrate from `music.apple.com`) for card Play, scrubber, selected sidebar row, current track title, and active lyric. Dock play/pause is primary-colored, not pink. No Sidra white glow. YouTube mark keeps its red.
- Library sidebar and player icons are heavier monochrome SF Symbols (semibold, ≥28pt hit target). The macOS application menu stays text.

Unless a task explicitly changes them, preserve:

- The persistent PlayerBar across browsing and detail navigation.
- Contextual previous/next behavior.
- Current queue, Up Next, history, repeat, shuffle, reorder, and persistence semantics.
- Artwork-led discovery, page-specific content patterns, and playlist detail hierarchy. Songs and playlist details use the approved D3 centered card-deck stage + expandable complete sortable table; playlists overview uses square cards; Home and New retain measured editorial hero regions.
- Songs, playlists, pins, recently played, search, and YouTube-import organization. Inbox tables remain on disk but have no chrome entry.
- Likes, pins, metadata, and playback-history preservation.
- YouTube resynchronization of imported playlists.
- Keyboard shortcuts, application menus, context menus, sharing.
- System media controls, notifications policy, and window restoration.
- Immediate language switching via `tr(_ en: String, _ zhHans: String, ...)`.

Do not restore:

- Folder/file scanning, `ScanRoot` settings, drag/drop of audio files, M3U file import, “Add Local”.
- Radio.
- A bottom video well. The on-demand YouTube video overlay (pauses audio; optional resume) is a product feature.

Albums, Artists, and Music Videos are approved under D2: Releases and Artists use stable YouTube-backed identities, Music Videos use the Track media-kind model, and Radio remains absent. Every restored destination must define refresh, stale-cache, loading, empty, unavailable, and collection-context playback behavior.

Do not simplify mature queue/history workflows merely to make implementation easier.

## UI and Design Philosophy

Muses should remain distinctly macOS-native. Prioritize artwork (and Now Playing video), hierarchy, depth, clarity, responsiveness, desktop information density, and an expressive playback surface.

Chrome layout follows live Apple Music Web: left nav (Search / Home / New + Library), page-specific editorial and table patterns, square shelves, integrated Queue, and a floating capsule player. Visual skin matches `music.apple.com`: pink accent, SF Pro, neutral surfaces, and restrained semantic glass. Native SwiftUI interpretation, not a WebView wrap of music.apple.com or music.youtube.com.

Avoid:

- Generic decorative glassmorphism on browsing cards.
- An enlarged iOS layout.
- Glow on idle icons, rail cards, or selected top tabs.
- Sidra white bloom as a stand-in for accent.

### Visual Hierarchy

- Browsing surfaces—Home, songs, playlists, search, and settings—should remain comparatively restrained and information-efficient.
- Playlist detail may use stronger artwork integration and purposeful motion.
- Now Playing is the primary expressive surface. Cover mode is a large square with title/artist beneath; vinyl (settings-only) is a circular spinning cover with no disc rim. Lyrics sit in the right column and can fill the slot. The dock keeps transport.
- Do not make every surface compete visually with Now Playing.
- Preserve legibility and functional control contrast over artwork-derived backgrounds in light, dark, and high-contrast appearances.
- Home includes a measured Apple Music Web editorial hero region, portrait Top Picks, and square shelves. New includes landscape editorial content, compact song matrices, and square shelves. Both pages stay calmer than Now Playing.
- Songs and playlist details center collection identity/actions above a virtualized, fan-shaped all-track hero deck. The deck has one canonical focus shared by drag, trackpad/wheel, chevrons, keyboard, and a first-to-last scrubber. Only hero-card activation performs the centered ember-burn playback ritual. A dedicated chevron handle or upward swipe replaces the stage with the complete sortable table inside the content pane; sidebar and PlayerBar remain. Songs defaults to title A–Z with no manual order; playlists default to their persisted Playlist Order. Table sorting never rewrites canonical order or playback context.
- Search is a dedicated destination with a centered field, source scope, categories, and grouped results. Settings is a centered native floating glass panel with an opaque accessibility fallback.
- Icon-first chrome: controls that can be an icon should be an icon, with `.help` and VoiceOver. Track titles, empty states, and settings explanations stay as text.
- YouTube affordances use `YouTubeMark` (red rounded play rectangle), not a generic SF Symbol stand-in.

## Liquid Glass Direction

Muses is expected to evolve toward deep integration with Apple's modern macOS Liquid Glass design language.

When performing explicitly scoped Liquid Glass work:

- Verify current platform APIs and availability for the supported macOS deployment range.
- Prefer native macOS structure, controls, toolbar/sidebar behavior, sheets, popovers, and system-provided glass first.
- Do not recreate native behavior unnecessarily.
- Remove legacy backgrounds or material layers when they conflict with the intended system glass composition.
- Use custom glass only for meaningful application-specific surfaces.
- Establish reusable primitives and semantic surface roles instead of scattering blur or material modifiers through individual views.
- Group related custom glass elements coherently; avoid fragmented floating decoration.
- Use tint only when it communicates selection, status, playback, or another clear semantic meaning. The accent for those states is Apple Music pink, not primary text and not a white glow.
- Preserve legibility over artwork and support light, dark, and high-contrast, and Reduce Transparency modes.
- Maintain appropriate fallback behavior when a supported OS does not provide the desired native API.

Liquid Glass must express hierarchy and interaction, not merely add decoration.

## Artwork

Artwork is a first-class part of the product identity.

- Preserve the artwork-led hierarchy and avoid obscuring covers behind excessive effects.
- Do not reduce image fidelity unnecessarily.
- Prefer a centralized resolution path for YouTube thumbnails, remote artwork, and placeholders.
- Guard asynchronous artwork, decoding, and palette results by current media identity so stale work cannot update a newer selection.
- Keep decoding, resizing, palette extraction, and blocking cache access out of SwiftUI `body`.
- Preserve graceful loading, placeholder, and failure states.
- Artwork-derived color may shape environment and depth, but functional UI must remain legible.
- Home rails crop YouTube thumbnails to square. Now Playing cover mode is a large square, not a 16:9 video slot.

## Motion

Motion should communicate hierarchy, navigation, continuity, playback state, expansion/collapse, or spatial relationships.

A centralized motion/continuity system may coordinate:

- Artwork continuity (PlayerBar ↔ Now Playing matched geometry).
- Glass morphing on **chrome only** (PlayerBar, Queue, compact controls).
- Queue presentation.
- Contextual controls and hover Play.
- History recap glyphs (appear-only; Reduce Motion → static).

Rules:

- Prefer continuity between related surfaces over unrelated transitions.
- Hover is 120–180ms ease, a few points of lift, no bounce, no idle motion on browsing surfaces.
- Playback-position and vinyl **may** animate. List rows and chrome **must not** sample those clocks.
- Do not glass-morph browsing cards.
- Do not add animation to high-frequency state without evaluating frame pacing, CPU, energy, and accessibility impact.
- Respect Reduce Motion in every new animation path, including custom Metal/AppKit rendering. Reduce Motion fallback is instant swap or opacity.

## Native macOS Interaction

Do not sacrifice desktop-native behavior for visual effects. Preserve and test:

- Pointer and hover behavior.
- Keyboard navigation, focus, focus rings, and existing shortcuts.
- Application menus and a complete track context menu on every track surface.
- Native sheets, popovers, Lists, Forms, toolbars, and window behavior.
- System media commands, notifications, and window restoration.

Prefer standard SwiftUI/macOS controls when they provide the required behavior. Custom controls must justify and replace any lost keyboard, focus, pointer, accessibility, and semantic behavior.

## Accessibility

Accessibility is part of design and implementation, not a final cleanup phase.

- Provide meaningful VoiceOver labels and values, especially for image-only controls and `YouTubeMark`.
- Preserve keyboard access and visible focus indication.
- Support high-contrast appearances.
- Honor Reduce Motion and Reduce Transparency.
- Maintain legibility over artwork, video, and glass.
- Use sufficiently large and predictable interaction targets.
- Evaluate accessibility from the rendered application, not source inspection alone.

## Performance and Real-Time Safety

Muses contains high-frequency media and visualization state. Treat performance as a design constraint, especially around:

- Playback-position and completion observation.
- Vinyl animation and lyrics timelines.
- Artwork loading, decoding, palette extraction, and large images.
- Large playlist lists and SwiftData refreshes.
- Queue persistence and rapid playback changes.
- WKWebView lifetime (one player, never per-row).

Rules:

- Do not broaden high-frequency observable state or subscriptions without a concrete need.
- Do not perform expensive or blocking work in SwiftUI `body`.
- Keep async work cancellable where stale results can affect current playback or artwork.
- Do not claim an optimization without profiling or concrete evidence.
- Label performance findings as measured, strongly suspected, or speculative.
- Visual enhancements must not noticeably degrade playback reliability, frame pacing, launch time, scrolling, CPU, memory, or energy use.

## High-Risk Areas

Changes touching these areas require narrow scope, explicit reasoning, and proportionate verification:

- `PlaybackService`
- `YouTubeEmbedEngine` and its WKWebView host
- `YouTubeStreamEngine` (primary production engine)
- `QueueService` and queue persistence
- `NowPlayingManager`
- `PlayerBar`
- `NowPlayingView`
- SwiftData schema, relationships, contexts, and migrations
- Artwork and stream caches
- YouTube import ownership and deletion semantics
- Packaging, signing, entitlements, and bundled `yt-dlp`

Do not opportunistically refactor these systems during unrelated visual tasks.

## Change Discipline

- Prefer incremental, independently reviewable changes.
- Keep refactors targeted to the task and explain why an established subsystem must change before modifying it.
- Preserve user changes and unrelated work in a dirty worktree.
- Avoid broad rewrites, unrelated cleanup, speculative abstractions, architecture changes hidden inside UI work, and new dependencies without clear justification.
- Do not treat unfamiliar implementation choices as mistakes before tracing their purpose and tests.
- Do not silently convert a visual task into a behavior, persistence, playback, or release change.
- Source code, identifiers, and comments in new or edited files are English. User-visible strings go through `tr`.

## Verification

Match verification to the risk and phase using an appropriate combination of:

- Build checks.
- Focused unit tests (embed engine uses a fake IFrame client; no live WebView in CI).
- Cross-subsystem integration tests.
- Runtime playback and interaction inspection.
- Rendered screenshots at relevant window sizes and appearances.
- Keyboard, pointer, menu, and focus testing.
- VoiceOver, Reduce Motion, Reduce Transparency, and high-contrast checks.

Visual work must be judged in the rendered application, not from source alone. Performance claims should be measured whenever practical. If a phase is explicitly read-only, do not run commands that create build, test, cache, or packaging artifacts.

## Known Investigation Areas

The following findings are candidates for separately scoped investigation. They are not automatically in scope and must not trigger unsolicited refactors:

- Possible overlapping observation loops in `NowPlayingManager`.
- Playback-load cancellation and rapid-selection races.
- Queue, current-index, history, and completion consistency.
- YouTube IFrame pausing when the parked player is too small or fully occluded (verify park size empirically).
- Videos that reject embedding even with cookies.
- IFrame suggested quality being ignored by YouTube.
- Artwork cache propagation, eviction, and asynchronous identity checks.
- Accessibility labeling and focus behavior.
- Reduce Transparency and complete Reduce Motion coverage.
