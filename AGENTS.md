# Muses Project Guidance

## Purpose and Scope

This file defines durable product, engineering, UX, design, performance, and verification rules for all work in this repository. It is persistent agent context, not a roadmap or task list.

Muses is a native macOS **YouTube-native music application**. The library is imported YouTube videos and playlists. Playback, queue, artwork-led browsing, a persistent PlayerBar, immersive Now Playing (video + vinyl), and native macOS integration remain the product. It is not a local-file media player and not a demo.

As of 2026-08-19 the local-file era is retired: no folder scanning, no file import, no `LocalAudioEngine` in the running app. Historical specs that describe a local + YouTube hybrid are superseded by `docs/superpowers/specs/2026-08-19-muses-youtube-native-redesign.md`.

## Source of Truth

Use this hierarchy when sources disagree:

1. Current executable source.
2. Current tests.
3. Current behavior verified at runtime.
4. Documentation and historical design notes.

Historical plans describe intent but do not override current implementation unless the task explicitly says so. Investigate uncertainty; do not guess. Distinguish confirmed facts, evidence-backed implications, and speculation.

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
- Persisted keys, model fields, identifiers, relationship delete rules, queue JSON, cache formats, and filesystem paths are compatibility contracts. Changing them requires an explicit migration and backward-compatibility plan.
- Keep `Album`, `Artist`, and `ScanRoot` tables on disk for this schema generation. Stop writing them. Do not drop tables in the same change that removes their UI.
- Keep expensive network, metadata, palette, and recommendation work out of SwiftUI `body`.
- Large playlist screens must use lazy stacks and snapshot values. Do not eager-`VStack` hundreds of SwiftData relationships.

### Media Sources

- The unified `Track` row remains, but new rows are YouTube-backed (`youTubeId` set). Existing local rows stay in the store and are hidden from browsing.
- YouTube playlist import creates `YouTubeImport` + `YouTubeImportItem` + lazy `.youtube` Track. Local additions to YouTube playlists are removed as a product feature.
- Preserve explicit deletion semantics: deleting an import and deleting its associated tracks are different operations.
- yt-dlp remains for playlist/search metadata and embed-fallback stream URLs. Happy-path playback does not wait on yt-dlp.
- Treat cookie settings, timeouts, signing, and personal-use distribution constraints as part of the product boundary.

## Product Contracts

Chrome (as of `docs/superpowers/specs/2026-08-20-muses-apple-music-web-visual.md`; supersedes Sidra black/white/glow):

- Left nav (live Apple Music Web): rounded pane with traffic lights, Muses wordmark, Search / Home / New (selected item is pink), then Library (Recently, Songs, History, Inbox) and playlists. Profile at the bottom opens Settings. No top-bar tabs. No Radio.
- Library pane is always visible unless the user collapsed it.
- Player is a floating glass capsule at the bottom of the content area, not a full-width dock. YouTube video occupies the AirPlay slot. Hidden under the YouTube video overlay.
- Now Playing fills the content slot (beside the sidebar, above the dock). Large square cover, title/artist under it, lyrics on the right. It does not duplicate transport. Dock lyrics toggles lyrics-focus inside Now Playing. Opening Now Playing closes the queue panel.
- Visual language matches Apple Music Web: SF Pro, near-black / near-white neutrals, accent `#FA586A` (calibrate from `music.apple.com`) for card Play, scrubber, selected sidebar row, current track title, and active lyric. Dock play/pause is primary-colored, not pink. No Sidra white glow. YouTube mark keeps its red. Selected top tabs are bold primary text, not pink.
- Top bar, Library sidebar, and player icons are heavier monochrome SF Symbols (semibold, ≥28pt hit target). The macOS application menu stays text.

Unless a task explicitly changes them, preserve:

- The persistent PlayerBar across browsing and detail navigation.
- Contextual previous/next behavior.
- Current queue, Up Next, history, repeat, shuffle, reorder, and persistence semantics.
- Artwork-led browsing (square rails) and playlist detail hierarchy.
- Songs, playlists, pins, recently played, search, inbox, and YouTube-import organization.
- Likes, pins, metadata, and playback-history preservation.
- YouTube resynchronization of imported playlists.
- Keyboard shortcuts, application menus, context menus, sharing.
- System media controls, notifications policy, and window restoration.
- Immediate language switching via `tr(_ en: String, _ zhHans: String, ...)`.

Do not restore:

- Folder/file scanning, `ScanRoot` settings, drag/drop of audio files, M3U file import, “Add Local”.
- Albums and Artists as sidebar destinations or browse surfaces.
- A bottom video well. The on-demand YouTube video overlay (pauses audio; optional resume) is a product feature.

Do not simplify mature queue/history workflows merely to make implementation easier.

## UI and Design Philosophy

Muses should remain distinctly macOS-native. Prioritize artwork (and Now Playing video), hierarchy, depth, clarity, responsiveness, desktop information density, and an expressive playback surface.

Chrome layout follows live Apple Music Web: left nav (Search / Home / New + Library), 16:9 editorial heroes, square album rails, floating capsule player. Visual skin matches `music.apple.com`: pink accent, SF Pro, glass capsule. Native SwiftUI clone, not a WebView wrap of music.apple.com or music.youtube.com.

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
- Home follows Apple Music Listen Now (Top Picks editorial cards, then square rails). New follows Apple Music New (featured slot + rails). Unified square card size with hover Play. They must stay calmer than Now Playing.
- Search types into the top-bar field and replaces main content after the first non-empty character. Settings is an Account content page, not a System Settings sheet.
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

- Playback-position and completion observation (IFrame time polls).
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
- `YouTubeStreamEngine` (fallback only)
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
