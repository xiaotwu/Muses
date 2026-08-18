# Muses Project Guidance

## Purpose and Scope

This file defines durable product, engineering, UX, design, performance, and verification rules for all work in this repository. It is persistent agent context, not a roadmap or task list.

Muses is a mature native macOS music application combining local-library management, YouTube-backed content, contextual queue-based playback, artwork-led browsing, persistent playback controls, immersive Now Playing, and native macOS integration. It is not a media-player demo. Preserve established workflows and mature behavior during visual or architectural work unless a task explicitly changes them.

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

- `PlaybackService` is the UI- and system-facing playback facade. Views, commands, and system integrations must not manipulate `LocalAudioEngine` or `YouTubeStreamEngine` independently.
- Preserve collection-context playback: playing from an album, artist, playlist, search result set, recent list, or YouTube import must retain meaningful previous/next context.
- Preserve the conceptual distinction between the current collection queue, explicit Up Next insertions, and history.
- Treat repeat, shuffle, previous/next, prepared playback, completion, queue markers, history recording, and queue persistence as one behavioral system. Changes to one require checking the others.
- Preserve cross-engine volume, EQ, spectrum, completion, and state synchronization.
- Treat the dual-node audio graph and its runtime I/O-cycle guard as intentional. Do not remove unusual AVFoundation safeguards without reproducing and understanding the conditions they address.

### Data and Concurrency

- Keep SwiftData model objects on their intended actor/context boundaries. Do not pass them into detached tasks, audio callbacks, or other real-time work.
- Preserve immutable `Sendable` value boundaries such as `TrackSnapshot` for playback, queueing, and detached computation.
- Continue the established fresh-context, UUID re-fetch pattern when mutating persisted objects unless an explicitly scoped architectural change replaces it.
- Persisted keys, model fields, identifiers, relationship delete rules, queue JSON, cache formats, and filesystem paths are compatibility contracts. Changing them requires an explicit migration and backward-compatibility plan.
- Keep expensive filesystem, network, metadata, palette, and recommendation work out of SwiftUI `body` and off real-time audio paths.

### Media Sources

- Preserve the unified `Track` representation for local and YouTube-backed media.
- Preserve the distinction between remotely synchronized YouTube playlist items and local-only additions. Local additions must never appear to synchronize back to YouTube.
- Preserve explicit deletion semantics: deleting an import and deleting its associated tracks are different operations.
- Treat the bundled `yt-dlp` process, cookie settings, timeouts, signing, and personal-use distribution constraints as part of the product boundary.

## Product Contracts

Unless a task explicitly changes them, preserve:

- The persistent PlayerBar across browsing and detail navigation.
- Contextual previous/next behavior.
- Current queue, Up Next, history, repeat, shuffle, reorder, and persistence semantics.
- Artwork-led browsing and detail hierarchy.
- Album, artist, song, playlist, pin, recent, search, and YouTube-import organization.
- Incremental library scanning and soft deletion of temporarily missing files.
- Likes, pins, metadata, and playback-history preservation during rescans.
- YouTube resynchronization while retaining local additions and intended Track ownership.
- Keyboard shortcuts, application menus, context menus, sharing, drag/drop, and file import/export.
- System media controls, notifications policy, window restoration, and Spotlight integration.
- Immediate bilingual switching and the existing `tr(en, zh)` convention.

Do not simplify mature workflows merely to make implementation easier.

## UI and Design Philosophy

Muses should remain distinctly macOS-native. Prioritize artwork, hierarchy, depth, clarity, responsiveness, desktop information density, and expressive playback experiences.

Avoid turning Muses into:

- Generic web-style glassmorphism.
- An enlarged iOS layout.
- A Spotify or Apple Music clone.
- An interface dominated by decorative effects.

Visual presentation may evolve substantially, but behavior, information architecture, keyboard efficiency, and native interaction must remain intact unless explicitly changed.

### Visual Hierarchy

- Browsing surfaces—library, albums, artists, playlists, search, and settings—should remain comparatively restrained and information-efficient.
- Album, artist, playlist, and other contextual detail surfaces may use stronger artwork integration and purposeful motion.
- Now Playing is the primary expressive surface. It may make deeper use of artwork, environmental color, visual depth, Liquid Glass, lyrics, spectrum, vinyl, motion, and playback metadata.
- Do not make every surface compete visually with Now Playing.
- Preserve legibility and functional control contrast over artwork-derived backgrounds in light, dark, and high-contrast appearances.

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
- Use tint only when it communicates selection, status, playback, or another clear semantic meaning.
- Preserve legibility over artwork and support light, dark, high-contrast, and Reduce Transparency modes.
- Maintain appropriate fallback behavior when a supported OS does not provide the desired native API.

Liquid Glass must express hierarchy and interaction, not merely add decoration.

## Artwork

Artwork is a first-class part of the product identity.

- Preserve the artwork-led hierarchy and avoid obscuring covers behind excessive effects.
- Do not reduce image fidelity unnecessarily.
- Prefer a centralized resolution path for cached local art, YouTube thumbnails, remote artwork, and placeholders.
- Guard asynchronous artwork, decoding, and palette results by current media identity so stale work cannot update a newer selection.
- Keep decoding, resizing, palette extraction, and blocking cache access out of SwiftUI `body` and real-time paths.
- Preserve graceful loading, placeholder, and failure states.
- Artwork-derived color may shape environment and depth, but functional UI must remain legible.

## Motion

Motion should communicate hierarchy, navigation, continuity, playback state, expansion/collapse, or spatial relationships.

- Prefer continuity between related surfaces, such as artwork-to-detail or PlayerBar-to-Now-Playing expansion, over unrelated transitions.
- A future centralized motion system may coordinate artwork continuity, glass morphing, queue presentation, contextual controls, and hover response.
- Avoid continuous decorative movement that competes with music, lyrics, spectrum, or artwork.
- Do not add animation to high-frequency state without evaluating frame pacing, CPU, energy, and accessibility impact.
- Respect Reduce Motion in every new animation path, including custom Metal/AppKit rendering.

## Native macOS Interaction

Do not sacrifice desktop-native behavior for visual effects. Preserve and test:

- Pointer and hover behavior.
- Keyboard navigation, focus, focus rings, and existing shortcuts.
- Application menus and context menus.
- Drag/drop, file importers, open/save panels, and sharing.
- Native sheets, popovers, Lists, Forms, toolbars, and window behavior.
- System media commands, notifications, Spotlight, and window restoration.

Prefer standard SwiftUI/macOS controls when they provide the required behavior. Custom controls must justify and replace any lost keyboard, focus, pointer, accessibility, and semantic behavior.

## Accessibility

Accessibility is part of design and implementation, not a final cleanup phase.

- Provide meaningful VoiceOver labels and values, especially for image-only controls.
- Preserve keyboard access and visible focus indication.
- Support high-contrast appearances.
- Honor Reduce Motion and Reduce Transparency.
- Maintain legibility over artwork and glass.
- Use sufficiently large and predictable interaction targets.
- Evaluate accessibility from the rendered application, not source inspection alone.

## Performance and Real-Time Safety

Muses contains high-frequency media and visualization state. Treat performance as a design constraint, especially around:

- Playback-position and completion observation.
- Spectrum capture and rendering.
- Vinyl animation and lyrics timelines.
- Artwork loading, decoding, palette extraction, and large images.
- Large grids, lists, and SwiftData refreshes.
- Queue persistence and rapid playback changes.
- Audio-thread work.

Rules:

- Do not broaden high-frequency observable state or subscriptions without a concrete need.
- Do not perform expensive or blocking work in SwiftUI `body`.
- Do not perform allocation-heavy, blocking, actor-hopping, logging-heavy, or filesystem/network work on real-time audio paths.
- Keep async work cancellable where stale results can affect current playback or artwork.
- Do not claim an optimization without profiling or concrete evidence.
- Label performance findings as measured, strongly suspected, or speculative.
- Visual enhancements must not noticeably degrade playback reliability, frame pacing, launch time, scrolling, CPU, memory, or energy use.

## High-Risk Areas

Changes touching these areas require narrow scope, explicit reasoning, and proportionate verification:

- `PlaybackService`
- `LocalAudioEngine`
- `YouTubeStreamEngine`
- `QueueService` and queue persistence
- `NowPlayingManager`
- Spectrum processing and rendering
- `PlayerBar`
- `NowPlayingView`
- SwiftData schema, relationships, contexts, and migrations
- Artwork, waveform, and stream caches
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

## Verification

Match verification to the risk and phase using an appropriate combination of:

- Build checks.
- Focused unit tests.
- Cross-subsystem integration tests.
- Runtime playback and interaction inspection.
- Rendered screenshots at relevant window sizes and appearances.
- Keyboard, pointer, menu, drag/drop, and focus testing.
- VoiceOver, Reduce Motion, Reduce Transparency, and high-contrast checks.
- Performance profiling and energy/memory inspection.
- Packaged-app, signing, Spotlight, notification, and deep-link verification when those systems change.

Visual work must be judged in the rendered application, not from source alone. Performance claims should be measured whenever practical. If a phase is explicitly read-only, do not run commands that create build, test, cache, or packaging artifacts.

## Known Investigation Areas

The following findings are candidates for separately scoped investigation. They are not automatically in scope and must not trigger unsolicited refactors:

- Possible overlapping observation loops in `NowPlayingManager`.
- Playback-load cancellation and rapid-selection races.
- Queue, current-index, history, and prepared-playback consistency.
- YouTube immediate-streaming and decoded-stream transition behavior.
- Real-time spectrum FFT allocation and setup costs.
- Artwork cache propagation, eviction, and asynchronous identity checks.
- Spotlight refresh, result activation, and OS-level URL registration.
- Accessibility labeling and focus behavior.
- Reduce Transparency and complete Reduce Motion coverage.
- Runtime seek/progress behavior across AVAudioPlayerNode scheduling and engine swaps.
- Settings that are exposed but not currently connected to runtime behavior.

