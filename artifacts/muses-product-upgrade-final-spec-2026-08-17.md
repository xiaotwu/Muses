# Muses Product Upgrade — Final Specification (Optimized)

**Status:** `READY_FOR_REVIEW` — awaiting explicit user confirmation.
**Date:** 2026-08-17
**Spec author:** ZCode, after repository-wide investigation of the actual Muses codebase.
**Source of truth priority:** (1) current executable source, (2) current tests, (3) runtime behavior, (4) this Final Spec after approval, (5) the initial product spec.

This document rewrites the initial product specification so it accurately describes how the requested feature set should be built *inside the real Muses project*. The initial spec is treated as product intent + constraints, not as immutable architecture. Product feature scope is preserved in full; technical architecture is adapted to the real codebase.

---

## 1. Repository Understanding Summary

Muses is a **native macOS SwiftUI/SwiftData music application** (SwiftPM executable, deployment target macOS 14, zero external dependencies). It is **not** an Electron/Tauri/WebView YouTube Music client. "YouTube Music" in this project means **yt-dlp audio streaming of YouTube videos for personal use** (no media download, no YouTube Music subscription, no DOM injection, no DRM handling).

### Architecture as it actually exists

- **Composition root:** `MusesApp` (`App/MusesApp.swift`) builds the `ModelContainer` and ~12 `@Observable @MainActor` services eagerly in `init`, injecting them via SwiftUI `.environment(_:)`. App-lifetime singletons; no parallel service instances are instantiated inside views.
- **Playback:** `PlaybackService` (`Services/Playback/PlaybackService.swift`) is the canonical façade over two `any PlayerEngine` conformers — `LocalAudioEngine` (AVAudioEngine, dual `AVAudioPlayerNode` for gapless/crossfade) and `YouTubeStreamEngine` (yt-dlp → AVAudioFile → same dual-node graph; AVPlayer fallback for immediate streaming). Engine swap is by `track.youTubeId != nil`. A documented `ioCycleReady` RunLoop guard prevents an ObjC NSException crash in headless/CI processes. `PlaybackService` owns no `currentTrack` field — it reads the active engine's `PlayerState.track`. Position is owned by the engine and is **never persisted**.
- **Queue:** `QueueService` (`Services/Queue/QueueService.swift`) — `items: [QueueItem]` (current collection queue), `currentIndex`, `upNext: [QueueItem]` (manual play-next, FIFO), `history: [QueueItem]` (back-stack, cap 200), `repeatMode`, `shuffle`, `originalOrder`. Persisted continuously as JSON blobs inside a single-row `QueueState` @Model. `QueueItem` is a value type carrying a `TrackSnapshot`.
- **Unified track:** `Track` (@Model) already unifies local + YouTube via `sourceRaw` (`local`/`youtube`); `.local` carries `filePath`, `.youtube` carries `youTubeId`. `TrackSnapshot` is the `Sendable` value currency crossing actor boundaries (queue, detached tasks).
- **Persistence:** SwiftData, single `MusesModelContainer`, schema `MusesSchema.v1` registering 10 @Model types (`Track, Album, Artist, ScanRoot, QueueState, EQPreset, YouTubeImport, YouTubeImportItem, Playlist, PlaylistItem`). On-disk at `~/Library/Application Support/Muses/muses.sqlite`. **No `VersionedSchema`/`SchemaMigrationPlan` exists** — autoschema lightweight migration only. All preferences live in `UserDefaults` via `PrefKey` + `@AppStorage` (no `UserPreferences` model).
- **Mutation pattern:** every mutating service method opens a **fresh `ModelContext`** on the main actor, re-fetches by UUID, mutates, saves, discards the context. `@Model` objects never cross actor/context boundaries; only `UUID` and `TrackSnapshot` do.
- **Lyrics:** `LyricsService` — line-synced LRC only; providers LRCLIB + Musixmatch (hardcoded public key) + local `.lrc` file; cached on `Track.lyrics`. No word-sync, no translation/romanization, no click-to-seek, no fullscreen, no desktop overlay.
- **Now Playing (Phase 15):** two-column overlay (art + lyrics + Up Next), artwork-derived gradient, cover/vinyl + lyrics toggles, spectrum, space-to-play. `NowPlayingManager` (250 ms polling) publishes `MPNowPlayingInfoCenter` and binds `MPRemoteCommandCenter`.
- **Desktop integration that EXISTS:** `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` (play/pause/next/prev/seek/±15s), opt-in `UNUserNotification`, Spotlight indexing (`CSSearchableIndex`) + `muses://play?trackId=` deep link (but **`CFBundleURLTypes` not registered in Info.plist**), in-app ⌘ shortcuts, drag/drop import, M3U import/export, `NSSharingServicePicker`, window frame autosave.
- **Desktop integration MISSING:** global system-wide hotkeys, mini player window, menu-bar/`NSStatusItem` tray, desktop/floating lyrics overlay, `CFBundleURLTypes` registration, `like`/`changeRepeatMode`/`changeShuffleMode` remote commands, multi-window authored support.
- **History today:** no `ListeningEvent`. Only `Track.playCount` + `Track.lastPlayedAt`, incremented on play-**start** (`LibraryService.recordPlay`). No skip/completion/outcome tracking, no per-listen duration, no aggregates/recaps.
- **Sessions today:** none. "Restore" = `QueueService.restore()` rehydrates the queue arrays/index/mode at launch but does **not** resume playback or position.
- **Local library:** already core — incremental scan, soft-delete of missing files (`availabilityRaw`), metadata extraction, enrichment, pins, recents, recommendations, mixed-source playlists. "Feature 11 Unified Local + YouTube" is **largely already done**.
- **EQ (10-band) + spectrum (Metal/Canvas, 30 Hz) + sleep timer + GitHub Release updater + i18n (en/zh `tr`) + pure B&W theme** all exist.
- **Tests:** 51 Swift test files, Swift Testing (`@Suite`/`@Test`), in-memory container, stub engines, mock yt-dlp, stub URL protocol. Smoke tests Phase1/2/3. `PackagingTests` validates scripts + Info.plist + entitlements.
- **Build/release:** `Package.swift` (SwiftPM) → `swift build` → `Scripts/build-app.sh` assembles `.app` bundle, `Makefile` `app` (ad-hoc) / `release` (Developer ID + notarize + DMG). `UpdateService` queries GitHub Releases API.

### "Parallel UI/UX task" — reality check

The dirty working tree is **not** a parallel UI/UX source edit. It is a **`NowPlayingManager` observation-loop bug fix** (a `AGENTS.md` High-Risk playback correctness change) plus its tests, surfaced by the `artifacts/playback-window-repro-2026-08-17/` reproduction audit (YouTube playback → main-actor starvation). `artifacts/` also contains an *untracked* `muses-visual-design-system-2026-08-17.md` (a design *specification*, explicitly "no production UI implemented by this document") and a 52-screenshot *baseline* (no source changed). Phase 15 (Now Playing redesign) is already committed (`efb3388`).

Therefore the initial spec's Electron/CSS/design-token merge-conflict framing does not map literally onto this repo. The **equivalent constraint already lives in `AGENTS.md`** ("do not turn Muses into a Spotify/Apple Music clone", "preserve mature workflows", "do not refactor high-risk systems opportunistically", Liquid Glass is a *future* direction). This Final Spec honors that constraint directly.

---

## 2. Major Changes Made to the Initial Spec

1. **Replaced the Electron/Tauri/WebView substrate with the native macOS SwiftUI/SwiftData reality.** Dropped all WebView/DOM/IPC/renderer/CSS/localStorage/YouTube-Music-DRM assumptions. There is no renderer process, no IPC, no CSS, no YouTube Music subscription, no DRM audio pipeline to negotiate.
2. **Reclassified "Feature 11 — Unified Local + YouTube Music" as EXTEND (largely DONE).** Unified `Track`, mixed-source playlists, and unified playback already work. Remaining work is hardening (optional content-hash identity, format-support verification), not a new subsystem.
3. **Mapped every spec abstraction to an existing one:** `UnifiedTrack` → `Track` + `TrackSnapshot`; `PlayerService` → `PlaybackService`; `QueueStore` → `QueueService`/`QueueState`; `EventBus` → a new lightweight `PlaybackEventBus` (the one new cross-cutting primitive); `Repository` → existing `LibraryService`/`PlaylistService` fresh-context pattern; `CommandRegistry` → new additive `CommandRegistry` (optional but recommended).
4. **Replaced the generic data model with the real SwiftData schema**, adding new @Model types only where a feature is genuinely missing (`ListeningEvent`, `ListeningSession`, `QueueGroup`, `InboxItem`, `TrackNote`, `TrackBookmark`, `AlbumNote`, `FocusSession`, `AutomationRule`) and extending existing models with **optional** fields only.
5. **Introduced a real migration infrastructure** (`VersionedSchema` v1 encapsulating the current 10 models + `SchemaMigrationPlan` v1→v2) — absent today — even though v1→v2 is purely additive, so future non-additive changes are safe.
6. **Honest capability classification** per macOS 14+ (SUPPORTED / SUPPORTED WITH LIMITATIONS / PLATFORM-LIMITED / NOT IMPLEMENTED). Notably: output-device switching is best-effort; word-synced/translation/romanization lyrics data is platform-limited (no free provider); weather context is not implemented (out of scope); headphone detection is heuristic.
7. **Repo-specific implementation order** (Phases 16–27) replacing the spec's provisional order, dependency-ordered against the real codebase (e.g. History needs the new event bus; Sessions need History's instrumentation; Focus needs Sessions + locked-queue; Desktop lyrics overlay needs the Advanced Lyrics engine).
8. **Preserved product intent in full** — no requested feature was silently removed. Where a capability is limited, the spec states Desired → Limitation → Best available → Fallback → Detection.
9. **Tightened "do not break UI/UX" to the real constraint:** don't regress Phase 15 Now Playing, don't alter the pure B&W theme, don't redesign existing surfaces, add new features as new components/modules behind feature flags, smallest-possible diffs on shared files (`PlayerBar`, `RootView`, `SidebarView`, `NowPlayingView`).
10. **Honest "do not fake" commitments** kept: never fabricate audio metadata, lyrics timing, active-app identity, output-device changes, or YouTube API success; expose disabled states with explanations.

---

## 3. Gap Analysis (per feature)

| # | Feature | Status | Current | Missing | Direction | Risk |
|---|---------|--------|---------|---------|-----------|------|
| 1 | Native Desktop | EXTEND+NEW | MPNowPlayingInfo/MPRemoteCommand (play/pause/next/prev/seek/±15s), opt-in notifications, Spotlight index+deep-link, in-app ⌘ shortcuts, drag/drop, sharing, window autosave | Global system-wide hotkeys; mini player window; `NSStatusItem` tray; desktop/floating lyrics overlay; `CFBundleURLTypes` registration; like/repeat/shuffle remote commands; multi-monitor restore | New `DesktopIntegrationService` + `NSStatusItem` + Carbon `RegisterEventHotKey` + `Window`/`NSPanel` scenes; fix Info.plist | Med — global hotkeys + multi-window are new surface area; must not spawn a 2nd playback engine |
| 2 | Contextual Listening | NEW | Nothing (only `playCount`/`lastPlayedAt`) | Context capture at playback transitions; opt-in active-app detection; device context; context-derived profiles | `ContextService` + `NSWorkspace.frontmostApplication.bundleIdentifier` (opt-in); store `contextSummaryJSON` on `ListeningEvent` | High privacy — must be opt-in, record bundle id only |
| 3 | Smart History | NEW | `Track.playCount`+`lastPlayedAt` on play-start only | `ListeningEvent` (started/ended/listenedMs/completion/outcome); skip/completion classification; aggregates; recaps; search/filter | `ListeningEvent` @Model + `HistoryService`; instrument `PlaybackService` via new `PlaybackEventBus` | Med — skip/stop/interrupt classification edge cases |
| 4 | Advanced Queue | EXTEND | items/upNext/history(200)/repeat/shuffle/reorder/persist | Queue groups; locked tracks; priority; per-item origin; queue-history (played/skipped/removed) with restore | Extend `QueueItem` value type + `QueueGroup` @Model; extend `QueueService` + `QueueState` JSON | Med — must preserve existing previous/next/collection-context semantics |
| 5 | Listening Sessions | NEW | None (queue restore only, no position/auto-resume) | Session abstraction (queue snapshot + position + restore-to-position); crash recovery; "Continue / Start fresh" | `ListeningSession` @Model + `SessionService`; checkpoint position to `QueueState`; restore-on-launch dialog | Med-High — must not silently replace user's intentional queue |
| 6 | Music Inbox | NEW | Nothing | `InboxItem` + state machine + accept/reject/snooze + entry points | `InboxItem` @Model + `InboxService` + `InboxView`; entries from PlayerBar overflow / context menus / automation | Low-Med |
| 7 | Notes & Bookmarks | NEW | Nothing | Track/album notes; timestamp bookmarks (click→seek); note search | `TrackNote`/`TrackBookmark`/`AlbumNote` @Model + `NotesService`; editors on detail views; bookmarks in Now Playing; search in `GlobalSearchService` | Low |
| 8 | Advanced Lyrics | EXTEND | Line-synced LRC; LRCLIB+Musixmatch+local; cache; active-line scroll | Word-sync; translation/romanization; click-to-seek; fullscreen; manual offset; desktop overlay | Extend `LyricLine`/`LyricsResult`; add tap→seek; fullscreen mode; `NSPanel` desktop overlay reusing same timing engine; offset pref | Med — word-sync/translation data availability is limited |
| 9 | Focus Mode | NEW | Sleep timer (closest analog) | Focus session; suppress discovery surfaces; timer; queue lock; optional Pomodoro | `FocusSession` @Model + `FocusService` + `FocusView`; gate Home/New discovery via `focus.isActive` | Med — suppression must not break navigation; no task management |
| 10 | Audio Nerd Mode | EXTEND | EQ (10-band)+spectrum exist; codec/sampleRate/bitDepth/replayGain on Track | Metadata panel; bitRate/channels; output device enum/switch; EQ bypass already exists | `AudioInfoPanel` view; add `bitRate`/`channels` to `Track`+`TrackSnapshot`; Core Audio device enum/switch (best-effort) | Med — output-device switch is platform-limited; never fabricate |
| 11 | Local + YouTube unified | EXTEND (mostly DONE) | Unified `Track`; mixed-source playlists; incremental scan; soft-delete; metadata; enrichment | Optional content-hash identity for moved/renamed files; format-support verification | Optional `partialContentHash` on `Track`; document supported formats (AVFoundation set) | Low |
| 12 | Context Automation | NEW | Nothing | Trigger/condition/action rules; cooldown; loop prevention | `AutomationRule` @Model + `AutomationService`; depends on Context (Phase 23) | Med — loop/cooldown correctness |

---

## 4. Platform Capability Matrix (macOS 14+)

| Capability | Classification | Notes |
|---|---|---|
| Global system-wide hotkeys | SUPPORTED | Carbon `RegisterEventHotKey` (still supported). Configurable, conflict detection. |
| Media keys | SUPPORTED | `MPRemoteCommandCenter` (already used). Do not register competing handlers. |
| Menu-bar / tray | SUPPORTED | `NSStatusItem` via `NSApplicationDelegateAdaptor`/controller. |
| Mini player window | SUPPORTED | Additional SwiftUI `Window`/`WindowGroup` or `NSPanel`; shares single `PlaybackService`. |
| Desktop lyrics overlay | SUPPORTED | Borderless always-on-top `NSPanel`, click-through optional; reuses `LyricsService` timing. |
| Multi-monitor | SUPPORTED | `NSScreen` enumeration; restore to visible monitor after topology change. |
| Active application detection | SUPPORTED, opt-in | `NSWorkspace.shared.frontmostApplication?.bundleIdentifier`. Record bundle id only. |
| Output device enumeration | SUPPORTED | Core Audio HAL `kAudioHardwarePropertyDevices`. |
| Output device switching | SUPPORTED WITH LIMITATIONS | `AVAudioEngine` routes to system default; per-device routing needs manual graph/`AVAudioIONode` output device id — best-effort, fallback to default. |
| Headphone detection | SUPPORTED WITH LIMITATIONS | Device transport type / name heuristic; not perfectly reliable. |
| Local filesystem / decode / metadata | SUPPORTED | Already used (`AVAudioFile`, `AVAsset`, `AVFoundation`). |
| Spectrum analysis | SUPPORTED | Already implemented (Metal + Canvas, 30 Hz). |
| Word-synced lyrics data | PLATFORM-LIMITED | No free provider; LRCLIB/Musixmatch provide line-sync only. Word-sync structure supported, falls back to line-sync. |
| Translation / romanization lyrics | PLATFORM-LIMITED | Data availability limited; structure supported, graceful fallback. |
| Weather context | NOT IMPLEMENTED | Needs network + location; out of scope. Document as future. |
| YouTube "Music" subscription | NOT APPLICABLE | This app uses yt-dlp (personal-use). No subscription, no DRM. |

---

## 5. UI/UX Conflict Strategy (adapted to this repo)

There is **no concurrent UI/UX source-editing effort** in the working tree (confirmed by `git status` + `git diff`). The dirty source is a `NowPlayingManager` playback bug fix. The durable UI constraint therefore comes from `AGENTS.md`, not from a parallel task:

- Do **not** redesign existing surfaces (sidebar, PlayerBar, Now Playing, settings, album/artist/playlist detail). Add new features as **new isolated components/modules** using existing primitives.
- Do **not** alter the pure B&W theme, typography, spacing tokens, or animations.
- Do **not** regress Phase 15 Now Playing (the most recent committed UI work).
- Do **not** opportunistically refactor `PlaybackService`/`LocalAudioEngine`/`YouTubeStreamEngine`/`QueueService`/`NowPlayingManager`/`PlayerBar`/`NowPlayingView`/SwiftData schema during unrelated feature work (`AGENTS.md` High-Risk Areas).
- When a shared file (`PlayerBar.swift`, `RootView.swift`, `SidebarView.swift`, `NowPlayingView.swift`) must change, make the **smallest possible diff**: no reformat, no unrelated renames, no reordering, no visual-value changes. Prefer wrapper/hook/command/store bindings over editing the shared file.
- Add new sidebar sections/views for new surfaces (Inbox, History, Focus, Audio Nerd) rather than displacing existing ones.
- Run `git status`/`git diff` before each implementation phase; never `git reset --hard`/`git clean -fd`/restore unrelated files.

---

## 6. Data Migration Plan

**Today:** autoschema lightweight migration only; no `VersionedSchema`/`SchemaMigrationPlan`.

**Change:** introduce `MusesSchemaV1` (`VersionedSchema`) encapsulating the current 10 @Model types, and `MusesMigrationPlan` (`SchemaMigrationPlan`) with a `.migrate(from: .v1, to: .v2)` stage. `MusesSchemaV2` adds the new @Model types and optional fields below. The v1→v2 stage is **additive only** (new tables + optional columns), so lightweight migration handles it; the plan exists so *future* non-additive changes are safe and tested.

**New @Model types (v2):**
- `ListeningEvent` — id, trackId, trackTitle, artist, albumTitle, source, startedAt, endedAt?, listenedMs, completionRatio?, outcomeRaw, contextSummaryJSON?, sessionId?
- `ListeningSession` — id, startedAt, updatedAt, endedAt?, statusRaw, queueSnapshotJSON, currentTrackId?, currentPositionMs?, contextSummaryJSON?
- `QueueGroup` — id, name, order, collapsed
- `InboxItem` — id, trackId + denormalized track snapshot fields, addedAt, sourceRaw, stateRaw, snoozeUntil?, listenedMs?, notes?
- `TrackNote` — id, trackId, content, createdAt, updatedAt
- `TrackBookmark` — id, trackId, timestampMs, title?, note?, createdAt
- `AlbumNote` — id, albumId, content, createdAt, updatedAt
- `FocusSession` — id, startedAt, plannedDurationMs?, endedAt?, playlistId?, listeningSessionId?, statusRaw
- `AutomationRule` — id, name, enabled, triggerRaw, conditionsJSON, actionRaw, cooldownMs?, lastFiredAt?

**Extended fields (all optional, lightweight-migratable):**
- `Track.bitRate: Int?`, `Track.channels: Int?`, `Track.partialContentHash: String?` (optional, Phase 27)
- `QueueState.currentTrackId: UUID?`, `QueueState.lastPositionMs: Double?`, `QueueState.groupsJSON: String?`
- `QueueItem` value type: `locked: Bool = false`, `groupId: UUID?`, `priority: Int?` (persisted inside `QueueState.itemsJSON`; backward-compat decoder defaults applied — see `TrackSnapshot.lyrics` precedent).

**Indexes:** add `@Index` on `ListeningEvent.trackId`, `ListeningEvent.startedAt`, `ListeningEvent.sessionId`, `InboxItem.stateRaw`, `TrackBookmark.trackId` for query performance at 100k+ events.

**Backfill:** past listening events **cannot** be reconstructed from `playCount`/`lastPlayedAt`. Migration starts history fresh; existing `playCount`/`lastPlayedAt` are preserved on `Track` (Home/Recommendations unaffected). Document this in the changelog.

**Failure recovery:** wrap `ModelContainer` construction in `do/catch`. On migration failure, **never destroy** the user DB — back up `muses.sqlite` to `muses-corrupt-<date>.sqlite`, fall back to an in-memory container, and surface a non-fatal alert. `PackagingTests` gains a migration test (v1 fixture → v2).

---

## 7. Architecture Decisions

| Decision | Reason | Rejected alternative |
|---|---|---|
| Reuse `PlaybackService` as the canonical player façade | Already owns engine swap, volume/EQ/spectrum/completion coordination | A new `PlayerService` — would create conflicting ownership |
| Introduce a new `PlaybackEventBus` (`@Observable @MainActor`, typed `PlaybackEvent` enum) | No event system exists today; History/Context/Session/Inbox all need lifecycle hooks. `library.playRevision` counters are too coarse | Polling each consumer independently (duplicated observation, the existing `NowPlayingManager` runaway risk) |
| Reuse `QueueService`/`QueueState` for advanced queue | Already owns queue state + persistence | A parallel `AdvancedQueueService` — conflicting ownership |
| `ListeningEvent` as a @Model with denormalized `trackTitle/artist/albumTitle` | History must remain queryable after a `Track` is deleted | A required `Track` relationship — would null/delete-cascade history |
| Position checkpoint on `QueueState` (not a new model) | `QueueState` is already the single queue-persistence row; one field pair is enough | A separate `PlaybackPosition` model — extra join for no benefit |
| `InboxItem` denormalizes a track snapshot (like `QueueItem`) | Inbox items must survive deletion of their source `Track`; playback still works via `youTubeId`/`filePath` snapshot | A required `Track` relationship |
| New surfaces as new files/components behind feature flags | Smallest diff on shared files; safe incremental rollout | Editing `PlayerBar`/`RootView`/`NowPlayingView` heavily |
| `VersionedSchema` v1→v2 introduced now | Makes future non-additive migrations testable; v1→v2 is additive so low risk | Continuing autoschema-only — fragile once non-additive changes appear |
| `NSStatusItem` + Carbon `RegisterEventHotKey` + `NSPanel` for desktop | Native macOS primitives; no new dependency | Electron-style global-shortcut library — not applicable |
| Word-sync/translation lyrics: structure supported, data fallback | No free word-sync provider; line-sync works today | Faking word-sync — violates capability honesty |
| Output-device switching: best-effort Core Audio, fallback to default | `AVAudioEngine` routes to system default; per-device routing is limited | Claiming reliable switching — would be faking |
| Weather context: NOT IMPLEMENTED | Needs network + location; out of product scope for a local-first music app | Adding a weather API dependency |

---

## 8. Persistence Boundaries

| State | In-memory? | Persisted? | When | Crash-recoverable? | Retention |
|---|---|---|---|---|---|
| Queue (items/upNext/history/mode/shuffle/groups) | yes | SwiftData `QueueState` JSON | every mutation (already) | yes | until replaced |
| Current track + position | yes (engine) | `QueueState.currentTrackId`+`lastPositionMs` | checkpoint every ~10s + on pause/quit | yes (±10s) | until next play |
| Listening events | no | `ListeningEvent` row | on Started/Completed/Skipped/Stopped | yes (last event may be "interrupted") | configurable; default unlimited, with cleanup job |
| Listening session | yes | `ListeningSession` row | on create/queue-mutation/periodic/end | yes | completed sessions retained for recaps; configurable |
| Inbox | yes | `InboxItem` row | on add/state-change | yes | until rejected/removed |
| Notes / bookmarks / album notes | yes | respective @Model | on create/update/delete | yes | until deleted |
| Focus session | yes | `FocusSession` row | on start/end | yes | retained for recaps |
| Automation rules | yes | `AutomationRule` row | on create/update | yes | until deleted |
| EQ presets / playlists / library | yes | existing @Models | existing | yes | existing |
| User preferences | `@AppStorage` | `UserDefaults` | on change | yes | existing |
| Artwork/stream/waveform caches | in-memory + on-disk | existing paths | existing | partial | no eviction today (unchanged in this spec) |

---

## 9. Failure & Recovery Model

- DB unavailable / migration fails → back up sqlite, fall back to in-memory container, non-fatal alert, playback continues against in-memory (re-scan required on next good launch).
- Lyrics provider fails → playback continues; cache-first; `LyricsResult` returns nil; UI shows "no lyrics".
- Local file missing → `Track.availability = .unavailable` (existing); playback skips to next; queue item marked skipped.
- Active-app detection fails/unauthorized → context continues without app identity.
- History aggregation fails → playback continues; aggregation retried by background job.
- Output-device switching unsupported → option disabled with explanation; playback continues on default.
- Session snapshot corrupted → recover queue from `QueueState` where possible, else start clean; never lose notes/inbox/history.
- Sleep/wake playback desync → on `NSWorkspace.didWakeNotification`, re-sync engine state (resume if was playing, else stay paused); checkpoint position.
- Automation execution failure → log, increment a per-rule failure counter, respect cooldown; never loop.
- Secondary window (mini/lyrics) crash → main window + playback unaffected (each window is independent SwiftUI scene sharing services).

**Playback availability is the highest operational priority.** Every new feature fails independently.

---

## 10. Revised Final Spec (feature-by-feature, implementation-ready)

### 10.1 Feature 1 — Native Desktop Experience
- **Global hotkeys:** `DesktopIntegrationService` (`@MainActor @Observable`) registers Carbon `RegisterEventHotKey` for configurable actions (Play/Pause, Next, Previous, Volume Up/Down, Mute, Like, Add to Inbox, Show/Hide Player, Show Mini Player, Show Lyrics, Toggle Focus Mode). Shortcuts stored in `UserDefaults` (`PrefKey.globalHotkeys` JSON), conflict detection, restore defaults. In-app ⌘ shortcuts and global hotkeys invoke the same `CommandRegistry` handlers.
- **Mini player:** new SwiftUI `WindowGroup("MiniPlayer")` (or `NSPanel`-backed) scene, contents: artwork, title/artist, prev/play/next, progress, like, queue/lyrics shortcuts, volume; always-on-top toggle; position+size via `setFrameAutosaveName`. Shares `PlaybackService` — **no second engine**. Multi-monitor aware (`NSScreen`).
- **Tray/menu bar:** `NSStatusItem` controller with menu: current track, play/pause, next, prev, like, add to inbox, open mini, open main, quit. Updates on `PlaybackEventBus.TrackStarted`.
- **Media keys / OS media:** already present; **add** `likeCommand`, `changeRepeatModeCommand`, `changeShuffleModeCommand` to `MPRemoteCommandCenter`.
- **Desktop lyrics overlay:** borderless always-on-top `NSPanel` reusing `LyricsService` + the same active-line computation as `LyricsView` (single timing engine — no second timer). Modes: normal/compact/single-line; settings: opacity, font size, alignment, position, lock. Click-through optional.
- **Spotlight:** **fix `CFBundleURLTypes` registration** in `Info.plist` for `muses://` (gap); add incremental re-index on scan/edit (today only `indexAll()` at launch).
- **Window restoration:** keep frame autosave; add restoration of selected sidebar section + Now Playing open/closed + queue open/closed via `SceneStorage`/`@SceneStorage`.

### 10.2 Feature 2 — Contextual Listening
- **Opt-in:** `PrefKey.contextEnabled`, `PrefKey.contextTrackActiveApp` (default off).
- **Capture:** `ContextService` builds a `ListeningContext` value at `PlaybackEventBus` transitions (TrackStarted/Completed/Skipped): localTime (hour, dayOfWeek), `frontmostApplication.bundleIdentifier` (if opt-in), output device name (Core Audio), headphone heuristic. **Never** record window title, URL, document, keystrokes, clipboard, screen, file contents.
- **Storage:** `ListeningEvent.contextSummaryJSON` (encoded `ListeningContext`).
- **Profiles:** local aggregates — "most played while coding", "late-night favorites", "morning tracks", "headphone favorites", "focus favorites", "weekend albums" — computed by `HistoryService` from `ListeningEvent` + context.
- **Weather:** NOT IMPLEMENTED (documented limitation).

### 10.3 Feature 3 — Smart Listening History
- **`ListeningEvent` @Model** as in §6.
- **Instrumentation:** `PlaybackService` posts `TrackStarted` (on `load`), `TrackCompleted` (on engine completion, ≥ skip threshold), `TrackSkipped` (on `next()`/`previous()` while current listened < `min(30s, 20% duration)`), `TrackStopped` (pause → later different track / app quit while playing). `HistoryService` subscribes to `PlaybackEventBus`.
- **Skip heuristic:** `listenedMs < min(30_000, 0.2 * durationMs)`.
- **Search/filter:** `HistoryService.query(...)` supports title/artist/album/date/time-of-day/source/application-context/completion/skip/play-count/session. UI exposes simplified controls initially; query layer supports advanced filters.
- **Aggregates/recaps:** daily/weekly/monthly/all-time — listening time, unique songs/artists, top tracks/albums/artists, most skipped, most repeated, longest session, discovery ratio, local-vs-YouTube ratio. `ListeningRecap` value. New `HistoryView` sidebar section.

### 10.4 Feature 4 — Advanced Queue
- **Extend `QueueItem` value type:** add `locked`, `groupId`, `priority`, keep `fromContext` as origin.
- **`QueueGroup` @Model** (id, name, order, collapsed) — persisted in `QueueState.groupsJSON`.
- **Locked tracks:** not removed by any future radio/recommendation injection (none today; semantics forward-looking); manual removal always allowed.
- **Insert modes:** Play now / Play next (exists) / Play after current group / Add to end (exists) / Add with priority.
- **Queue history:** extend `QueueService.history` entries with a state tag (played/skipped/removed); allow Replay and Restore-to-queue from `QueueDrawerView`.

### 10.5 Feature 5 — Listening Sessions
- **`ListeningSession` @Model** as in §6.
- **Lifecycle:** auto-created on first playback after launch; updated on queue mutation + periodic position checkpoint; ended on explicit stop or long idle.
- **Restore:** on launch, if an unfinished session exists, present "Continue previous session / Start fresh" — never silently replace the user's queue. Continue = reload `queueSnapshotJSON`, set `currentIndex`, `loadCurrent()`, seek to `min(currentPositionMs, duration-2s)`.
- **Crash recovery:** queue + current track + position + groups + locked state + active session survive crashes (position ±10s).

### 10.6 Feature 6 — Music Inbox
- **`InboxItem` @Model** as in §6. State machine: unheard → listening → (accepted | rejected | snoozed); snoozed → unheard on due.
- **Actions:** Play, Play next, Accept (like + optional add-to-playlist + keep metadata), Reject (remove + optional negative signal + reason), Snooze (later today / tomorrow / this weekend / next week / custom), Add note, Remove.
- **Entry points:** PlayerBar overflow "Add to Inbox", track/album context menus, automation action, YouTube-import "save to inbox".
- **`InboxService` + `InboxView`** (new sidebar section). Does not mutate YouTube state on accept.

### 10.7 Feature 7 — Notes & Timestamp Bookmarks
- **`TrackNote`/`TrackBookmark`/`AlbumNote` @Model** as in §6.
- **Bookmark click → seek** to `timestampMs`. Editors on track/album detail (new isolated sheets, smallest diff on detail views). Bookmarks list in Now Playing. Note search added to `GlobalSearchService` (new "Notes" section) + `SpotlightIndexer` (optional).

### 10.8 Feature 8 — Advanced Lyrics
- **Extend `LyricLine`:** optional `words: [LyricWord]?` (text, startMs, endMs), `translation: String?`. **Extend `LyricsResult`:** `translations: [LyricsTranslation]?`, `romanization: LyricsResult?`, `offsetMs: Int?`.
- **Click-to-seek:** tap gesture on a timed `LyricLine` → `playback.seek(to: line.time + offset)`.
- **Manual offset:** `PrefKey.lyricsOffsetMs` per-track (stored on `Track.lyricsOffsetMs` optional).
- **Fullscreen lyrics:** new mode in `NowPlayingView` (artwork+lyrics / lyrics-only / minimal single-line) — toggled, not a redesign.
- **Word-sync / translation / romanization:** structure supported; **data is platform-limited** — fallback chain word→line→plain. Never fabricate.
- **Desktop overlay:** reuses the same `LyricsService` + active-line engine (no second timer) — built in Phase 24 with desktop integration.

### 10.9 Feature 9 — Focus Mode
- **`FocusSession` @Model** as in §6. `FocusService` (`@MainActor @Observable`).
- **When active:** suppress Home Top Picks / New recommendations / discovery surfaces (gate via `focus.isActive` in `HomeView`/`NewView` — smallest diffs); prioritize current track/queue/lyrics/minimal controls. Visual presentation subordinate to existing Now Playing.
- **Timer:** 25/45/60/90/custom/no timer; expiration: keep playing / pause / notify only.
- **Queue lock:** option to lock the Focus Session queue (respects locked tracks; recommendation injection — when added — must not replace). Manual edits allowed.
- **Lightweight Pomodoro** optional (25 focus + 5 break). **No task/project/todo management.**

### 10.10 Feature 10 — Audio Nerd Mode
- **`AudioInfoPanel`** (new view, opt-in) showing **real** metadata: codec, container, bitrate, sample rate, bit depth, channels, source, output device, replayGain, EQ state, volume normalization. Add `Track.bitRate`/`Track.channels` + reflect in `TrackSnapshot` (from `AVAudioStreamBasicDescription` already read by `MetadataService`). YouTube codec from yt-dlp format.
- **Output device:** enumerate (Core Audio), switch (best-effort; fallback to default with explanation), detect changes, remember preferred.
- **EQ:** already 10-band with bypass — exposed in panel. **Spectrum:** already exists — exposed in panel.
- **Never fabricate** any field; show "Unknown" when unavailable.

### 10.11 Feature 11 — Unified Local + YouTube (EXTEND, mostly done)
- Already unified. **Hardening:** optional `Track.partialContentHash` (first 64 KB hash) for moved/renamed detection (Phase 27, optional); document supported formats = AVFoundation set (MP3/AAC/M4A/ALAC/FLAC/WAV/CAF; Opus in CAF; raw OGG/Opus may be unsupported — test and document). Mixed-source playlists already work.

### 10.12 Cross-cutting primitives
- **`PlaybackEventBus`** (`@Observable @MainActor`): typed `PlaybackEvent` enum — TrackStarted/TrackPaused/TrackResumed/TrackSeeked/TrackCompleted/TrackSkipped/QueueChanged/PlaybackSourceChanged/OutputDeviceChanged/AppContextChanged/FocusSessionStarted/FocusSessionEnded. `PlaybackService` posts; `HistoryService`, `SessionService`, `ContextService`, `InboxService`, `NowPlayingManager`, `FocusService` subscribe. Replaces the coarse `library.playRevision` pattern for lifecycle hooks (playRevision remains for like/pin UI refresh).
- **`CommandRegistry`**: `id → () async throws -> Void` + `enabled()`. Existing ⌘ shortcuts + new global hotkeys + PlayerBar buttons + menu items invoke the same handlers. Command-palette NOT implemented (future-compatible only).
- **`FeatureFlags`**: `@AppStorage` bools — `ffSmartHistory`, `ffSessions`, `ffAdvancedQueue`, `ffInbox`, `ffNotes`, `ffAdvancedLyrics`, `ffFocusMode`, `ffAudioNerd`, `ffContext`, `ffAutomation`, `ffMiniPlayer`, `ffTray`, `ffDesktopLyrics`, `ffGlobalHotkeys`. Default: existing behavior + opt-in. No new feature may prevent existing playback from functioning.
- **`JobScheduler`**: lightweight `Task`-based — history aggregation, recap generation, context aggregation, lyrics cache maintenance, library scan (already detached). Cancellable, off-startup, crash-tolerant.
- **`RuntimeCapabilities`**: model (`@MainActor @Observable`) reporting SUPPORTED/LIMITED/UNSUPPORTED per capability; new features gate UI on this instead of assuming.

---

## 11. Implementation Phases (repo-specific, dependency-ordered)

> Numbers continue the existing phase sequence (last committed = Phase 15).

**Phase 16 — Foundation.** `VersionedSchema` v1 + `SchemaMigrationPlan` v1→v2; `FeatureFlags`; `PlaybackEventBus` + wire `PlaybackService` to post events (no behavior change yet); `CommandRegistry` (wire existing ⌘ shortcuts through it); `RuntimeCapabilities`; extend `Track`/`TrackSnapshot` (`bitRate`, `channels`) + `QueueState` (`currentTrackId`, `lastPositionMs`, `groupsJSON`); `QueueItem` (`locked`, `groupId`, `priority` with backward-compat decoder). *Acceptance: 177 tests green; existing playback behaves identically.*

**Phase 17 — Smart Listening History.** `ListeningEvent` @Model + `HistoryService` + `PlaybackService` instrumentation (Started/Completed/Skipped/Stopped) via event bus + skip heuristic + aggregates/recaps + `HistoryView`. *Depends on 16.*

**Phase 18 — Listening Sessions + Crash Recovery.** `ListeningSession` @Model + `SessionService` + position checkpoint + restore-on-launch dialog + crash recovery + sleep/wake re-sync. *Depends on 16, 17.*

**Phase 19 — Advanced Queue.** `QueueGroup` @Model + locked tracks + priority + insert modes + queue-history (played/skipped/removed) with restore + extend `QueueService` + `QueueDrawerView` updates (smallest diff). *Depends on 16.*

**Phase 20 — Music Inbox.** `InboxItem` @Model + `InboxService` + state machine + accept/reject/snooze + `InboxView` + entry points (PlayerBar overflow, context menus, automation). *Depends on 16.*

**Phase 21 — Notes & Bookmarks.** `TrackNote`/`TrackBookmark`/`AlbumNote` @Model + `NotesService` + editors + bookmark→seek + note search in `GlobalSearchService`. *Depends on 16.*

**Phase 22 — Advanced Lyrics (in-app).** word/translation/romanization model + click-to-seek + fullscreen mode + manual offset + data fallback. *Depends on 16.* (Desktop overlay deferred to 24.)

**Phase 23 — Contextual Listening + Automation.** `ContextService` (opt-in active-app) + context on `ListeningEvent` + profiles/aggregates + `AutomationRule` @Model + `AutomationService` (triggers/conditions/actions/cooldown/loop prevention). *Depends on 17.*

**Phase 24 — Native Desktop Integration.** global hotkeys + mini player window + `NSStatusItem` tray + desktop lyrics overlay (reusing lyrics engine) + `CFBundleURLTypes` fix + MPRemoteCommand gaps (like/repeat/shuffle) + multi-monitor. *Depends on 16, 22.*

**Phase 25 — Focus Mode.** `FocusSession` @Model + `FocusService` + `FocusView` + discovery suppression (smallest diffs on Home/New) + timer + queue lock + optional Pomodoro. *Depends on 18, 19, 16.*

**Phase 26 — Audio Nerd Mode.** `AudioInfoPanel` + real metadata exposure + Core Audio output device enum/switch (best-effort) + EQ/spectrum integration. *Depends on 16.*

**Phase 27 — Local Music hardening (optional).** optional `partialContentHash` for moved/renamed detection + format-support verification + mixed-source edge cases. *Depends on 16.* (Mostly already done.)

Each phase: feature-flagged, additive, tested, no regression. Phase 16 must land before any feature phase.

---

## 12. Testing Plan

Extend the existing Swift Testing pattern (in-memory container, stub engines, mock yt-dlp, stub URL protocol).

- **Unit:** queue ordering/locks/groups/priority; session persistence+restore; inbox state transitions; history aggregation; skip/completion classification; context automation matching; focus timer state; lyrics sync (line + click-seek + offset); local-track identity (partial hash); migration v1→v2.
- **Integration:** TrackStarted→History recorded; TrackStarted→Context snapshot (opt-in); Inbox item played→state updated; queue change→session updated; local track→PlaybackService→history; YouTube track→PlaybackService→history; Focus Mode→queue lock; lyrics timestamp click→seek; bookmark click→seek; global hotkey→command→playback; mini player sync with main; automation trigger→action with cooldown.
- **E2E smoke (new):** Scenario A (launch→play YT→pause→resume→next→history recorded); Scenario B (3 inbox items→listen→accept/reject/snooze→restart→preserved); Scenario C (advanced queue→group→lock→save session→restart→resume); Scenario D (add local folder→scan→play local→switch to YT→switch back); Scenario E (focus 45min→surfaces suppressed→exit→restored).
- **Migration test:** v1 fixture DB → v2; assert new tables/fields + preserved data + no destruction on failure.
- **Performance:** 100k `ListeningEvent` query < 200ms; 10k local tracks usable; spectrum allocation/setup unchanged or improved (per AGENTS investigation area).
- **Platform/manual:** global hotkey conflict; mini player multi-monitor; tray updates; desktop lyrics always-on-top + Reduce Motion; output-device switch fallback; VoiceOver labels on new controls; Reduce Transparency; high-contrast.
- **Regression (No-Regression Checklist):** existing playback/search/playlists/theme/navigation/keyboard/drag-drop/i18n/Spotlight/notifications all green; 177 baseline tests stay green; `git status` clean of unrelated changes each phase.

---

## 13. Risk Register

| Risk | Impact | Mitigation |
|---|---|---|
| `PlaybackService` instrumentation breaks gapless/completion | High (High-Risk area) | Phase 16 event-bus posts are **additive observation only** — no change to existing completion/swap logic; full regression suite; smallest diff |
| Global hotkeys / multi-window introduce a 2nd playback engine | High | Mini/lyrics/tray windows **share** `PlaybackService` via environment; no engine instantiation outside composition root |
| SwiftData migration corrupts user DB | High | `VersionedSchema` plan + v1→v2 additive only + failure → backup + in-memory fallback, never destroy; migration test |
| 100k+ `ListeningEvent` degrades queries | Med | `@Index` on trackId/startedAt/sessionId; pagination; background aggregation jobs; never load all into UI |
| Word-sync/translation lyrics over-promised | Med | Capability matrix states platform-limited; fallback word→line→plain; never fabricate |
| Output-device switch unreliable | Med | Best-effort Core Audio; fallback to default with disabled+explained UI |
| Context active-app tracking privacy | High | Opt-in default off; bundle id only; never window title/URL/content; clear data-deletion path |
| Automation loops / runaway | Med | Cooldown per rule; loop-prevention guard; per-rule failure counter; capped re-fire |
| Spectrum per-frame allocation (existing AGENTS area) | Med | Left to a separately scoped perf task; not opportunistically refactored here |
| NowPlayingManager observation runaway (existing fix in tree) | High | Preserve the in-flight 250ms polling fix; Phase 16 event bus does not reintroduce `withObservationTracking` recursion |
| Parallel design-system work in `artifacts/` conflicts | Low | It is untracked spec, not source; this Final Spec adds new components, doesn't edit design tokens |

---

## 14. Definition of Done (per feature)

Per the initial spec's DoD sections, carried forward and mapped to this repo: each feature is done when wired UI/Command → domain → persistence/platform → state update → recovery → tests, behind a feature flag, with no regression and no fabricated capabilities. Unsupported capabilities are detected and disabled with explanation, never faked.

---

## 15. Authority & Freeze

After explicit user confirmation, `SPEC_STATUS = APPROVED` and this document becomes the implementation source of truth. Authority order: (1) explicit latest user instruction, (2) this approved Final Spec, (3) `AGENTS.md` execution/safety protocol, (4) initial product spec, (5) generic examples. Mandatory regardless: do not destroy parallel/design work, do not destroy user data, do not fake unsupported functionality, do not silently weaken privacy, use safe migrations, keep feature failures isolated.

Minor non-user-visible implementation changes do not require re-approval. **Material changes** (removing a requested feature, changing user-visible behavior, introducing a remote backend, changing privacy behavior, replacing storage architecture, changing canonical playback ownership, abandoning an acceptance criterion) require spec revision + re-confirmation.