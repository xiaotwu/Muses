# Muses — Apple Music Web reconstruction

- **Date:** 2026-08-20
- **Status:** Approved; implementation in progress
- **Visual source of truth:** live `music.apple.com` for chrome and visual language; live signed-in `music.youtube.com` for Home information architecture and personalized content patterns
- **Supersedes:** `2026-08-20-muses-apple-music-web-visual.md`, `2026-08-20-muses-sidra-chrome.md`, and contradictory visual clauses in older plans
- **Product boundary:** native macOS, YouTube-native playback and library

## 1. Objective

Reconstruct Muses as a precise, native macOS interpretation of the current Apple Music Web Player. The result must inherit Apple Music Web's hierarchy, density, spacing, typography, page-specific content patterns, neutral palette, pink semantic accent, floating player, and restrained use of glass without becoming a WebView wrapper or an enlarged iOS layout.

This is a system reconstruction, not a sequence of unrelated cosmetic patches. Window chrome, navigation, responsive geometry, reusable surfaces, page templates, PlayerBar, Queue, Settings, Now Playing, accessibility, and performance must resolve into one coherent language.

## 2. Authority and evidence

For this reconstruction, resolve conflicts in this order:

1. Explicit user decisions recorded in this specification.
2. This specification and its approved decision log.
3. Live Apple Music Web behavior measured at the same window size and appearance.
4. Current executable behavior, where it does not conflict with items 1–3.
5. Current tests.
6. Historical specifications and plans.

Tests that encode a superseded visual or product contract must be updated; they are not evidence that an obsolete design should survive.

## 3. Confirmed decisions

1. Current Apple Music Web is the highest visual reference. Contradictory older Muses visual specifications are superseded.
2. Muses is strictly YouTube-native. Running local-folder scanning, local-file import, M3U workflows, local playback fallback, and local additions to YouTube playlists are retired.
3. Do not restore Radio.
4. Keep Muses' product identity and data sources. Copy Apple Music's design system and page patterns, not its catalog or branding.
5. Use page-specific patterns:
   - Home: reproduce the current signed-in YouTube Music Home feed's content hierarchy and section types inside Muses' native Apple Music Web-inspired shell.
   - Discover: landscape editorial content plus compact song matrices and shelves. This destination was formerly named New.
   - Songs and playlist details: dense track tables.
   - Playlists overview: square artwork cards.
   - Search: one independent floating search window with source scope, categories, and structured results. Search is not rendered as a main-content destination.
6. Queue is an integrated, full-height trailing pane rather than a floating glass drawer.
7. Settings remains a focused native floating glass window/panel rather than an Apple Music account page inside browsing content.
8. Preserve the current dirty worktree as the implementation baseline. Do not reset it merely to obtain a smaller diff.
9. Browsing and public playback work in guest mode. YouTube sign-in enhances personalization and owned-playlist synchronization; it is never a launch gate.
10. The first release exposes one active YouTube account at a time, while persisted remote data remains scoped by the account channel ID so switching accounts never overwrites another account's state.

## 4. Approved decision log

The former D1–D3 gates were resolved with the user on 2026-08-20. These decisions replace the temporary restrictions that previously guarded them.

### D1 — Clean V3 persistence cutover

Muses will replace indefinite legacy-schema compatibility with a one-time logical snapshot/import into a clean YouTube-native V3 store.

- Export user-owned truth before cutover: playable YouTube tracks, likes, editable metadata, playlists and item order, YouTube imports and item order, queue state, listening history, notes/bookmarks, pins, settings that belong in the store, and stable identifiers needed by those relationships.
- Do not copy retired local-file rows, `ScanRoot`, scanner state, M3U state, local-only imports, or rebuildable catalog caches into V3.
- Build and validate the V3 store at a distinct URL. Verify entity counts, identifiers, required YouTube IDs, relationship integrity, and playlist order before activating it.
- Keep the legacy physical store untouched while exporting, importing, validating, and activating the replacement store. Pointer activation alone never deletes source data.
- The user approved complete legacy removal on 2026-08-24. After manifest-complete validation, relationship/order/hash verification, and a successful cold restart that proves the active store does not depend on the pre-V3 family, delete that legacy SQLite family and its migration-source copies, logical snapshots, old-schema reader, compatibility tests, and inactive fallback path.
- No long-term migration capsule or migration chain back to the local-file schema remains after that cleanup gate. A fresh install creates only the current clean store.

### D2 — Releases and Artists

Albums and Artists return as YouTube-backed catalog destinations. Music Videos and Radio are not standalone destinations.

- A release is identified by a stable YouTube Music browse or playlist ID. Title/artist text alone is never sufficient identity.
- An artist is identified by a stable YouTube channel or YouTube Music browse ID. Never merge artists solely because their display names match.
- Existing `musicVideo` media-kind values remain decode-compatible, but video-backed rows appear as ordinary playable Tracks in Songs, playlists, and Search rather than a separate category.
- Separate user-owned truth from rebuildable catalog projections. Likes, playlist membership/order, history, notes, and user metadata survive; fetched release/artist membership and artwork can be refreshed or rebuilt.
- Every restored destination must preserve collection-context playback and define loading, empty, stale-cache, refresh, and unavailable-item states.

### D3 — Songs and playlist collection composition

Songs and every playlist detail use one collection-page composition.

- Center the collection name, metadata, and compact controls above a tactile fan-shaped deck of portrait hero cards. At roomy widths show approximately nine nearby cards; at the 840×600 minimum show approximately five. Render only the nearby window while the scrubber and navigation still address every canonical item from first to last.
- The focused card is upright and highest. Neighboring cards follow a restrained arc with progressive rotation, vertical offset, scale, and z-order. Hover spreads the fan slightly and lifts only the hovered card; it must not add glow or idle motion.
- Pointer drag, trackpad/wheel delta, chevrons, Left/Right/Home/End, and the first-to-last scrubber share one focused index and deterministic snapping. The scrubber navigates only and never reorders; its thumb is neutral transparent Liquid Glass with a white focus halo and an opaque accessibility fallback, never an accent-red selection ring.
- Hero-card activation starts playback immediately and keeps the complete deck operable. The active hero card rises 14pt from the fan, scales to 1.05, and gains a restrained two-layer halo derived from its own artwork; it never spawns a duplicate, dims the stage, or uses an ember/burn effect. Pointer, keyboard, and VoiceOver activation share this behavior, while opening a context menu does not activate the card.
- A dedicated chevron-up handle below the scrubber, or a direction-locked upward gesture from that handle zone, opens the complete table as a content-pane full-list mode. Sidebar and floating PlayerBar remain visible. A mirrored down handle, downward gesture, and Escape return to the deck while preserving deck focus plus table sort and scroll state.
- The full-list mode shows all tracks in a dense native macOS table with artwork/title, liked state, artist, release/album, year, genre/type, duration, date added, play count, source, and row actions when data exists.
- Columns are sortable and customizable. Sorting is a browsing projection only; it does not rewrite playlist order or silently change playback context.
- Songs uses title A–Z as its canonical/default order and does not support manual reordering.
- A user playlist uses `PlaylistItem.order`; a YouTube import uses `YouTubeImportItem.order`. Their default table sort is `Playlist Order`.
- Reduce Motion keeps the artwork-derived active-card halo but removes the lift and scale. Reduce Transparency does not turn browsing cards into glass; only the dedicated scrubber thumb uses semantic glass with an opaque neutral fallback.

### D4 — YouTube account and Home feed

Muses owns the Google Desktop OAuth client configuration. End users never enter a client ID, client secret, or redirect URI.

- Sign-in opens the user's default browser and completes through a loopback callback with PKCE. Tokens are stored in Keychain. Settings shows account identity, granted capabilities, reconnect, and sign-out—not developer credentials.
- Request only the scopes required by enabled features. Read identity/library signals independently from the manage-playlists permission so a declined write scope does not disable guest or read-only behavior.
- Official YouTube Data API v3 remains the durable source for account identity, owned playlists, subscriptions, liked videos, and write operations.
- Home uses an approved A+B capability model. Official account signals, public discovery, and local listening signals form the durable native baseline; this baseline remains independently usable when no signed-in web session exists.
- A separately isolated signed-in YouTube Music web-session adapter may enhance that baseline with real personalized YouTube Music sections. It is optional and volatile, and is never persisted user truth, a write-authorization source, or the playback engine.
- Both providers expose normalized value snapshots containing account scope, source, section identity, layout kind, title/subtitle, browse/play endpoints, stable media identity, artwork, availability, schema version, and freshness. Their caches remain account-scoped and source-separated. SwiftUI views never parse web payloads.
- If the private Home capability is disabled, expires, changes shape, belongs to another account, or is unavailable, Home first shows the last successful same-account Web snapshot with a stale indicator and retry action when safe, then continues with the official baseline. The UI must not describe baseline-only content as a full YouTube Music Home replica, and a failure never becomes an unexplained empty page.
- Sign-out clears tokens and volatile session material but retains account-scoped local snapshots, revisions, and playlists. They remain dormant until that same channel ID signs in again.
- Before switching accounts, pending local changes remain saved. Push is disabled until the active account matches the playlist owner; Muses never pushes account A's changes while account B is active.
- The login surface explains what account data is read, what playlist changes can be written, which data stays on the Mac, and how to revoke access.

### D5 — Search and Discover navigation

- Search is a single floating window opened from the sidebar, menu, or keyboard shortcut. Opening it focuses the existing window instead of creating parallel search state.
- The main content has no Search route, placeholder page, or duplicated result model. Closing Search returns focus to the previous main window context.
- The former New destination is named Discover / 发现. Its content contract remains discovery-oriented and distinct from the personalized Home feed.

### D6 — Explicit YouTube playlist synchronization and recovery

Imported or connected YouTube playlists use explicit, independent Pull and Push operations. Background work may refresh remote metadata into a Remote Shadow, but never mutates the local playlist or YouTube without user confirmation.

- Each account-scoped playlist maintains three states: Base (last accepted common revision), Local, and Remote Shadow (latest fetched remote state). Comparisons use ordered playlist-item identities, not `videoId` alone.
- Preserve `playlistItemId`, because YouTube permits the same video more than once. Duplicate videos remain separate ordered items. Private, deleted, unavailable, or region-blocked entries remain visible as unavailable placeholders when identity is known.
- Pull fetches Remote Shadow, previews additions/removals/moves/metadata changes, resolves conflicts item by item, then updates Local and Base only after confirmation. It never writes YouTube.
- Push runs an ownership/account/scope/quota preflight, previews the mutation plan, then writes only YouTube. It never silently replaces Local with a newly fetched list.
- A conflict is resolved per item. Ordering conflicts use one visual drag result. The resolved local revision is saved before an optional Push.
- YouTube writes are non-atomic. Push uses an idempotent operation journal keyed by playlist/item/target position, records every completed remote operation, reports partial success, and can resume without replaying completed steps.
- API failures distinguish authentication, permission/ownership, quota exhaustion, rate limiting, unavailable items, network loss, and malformed responses. Retry uses bounded backoff only for retryable failures and honors cancellation.
- User-owned playlists can Push. Liked Music, auto/system playlists, and playlists not owned by the active channel are read-only.
- Before every accepted Pull, local edit batch, restore, delete, or Push, save a metadata-and-order revision. Keep the last 50 revisions or 90 days, whichever retains more; pinned revisions are kept until unpinned.
- Deleted playlists remain in Recently Deleted for 30 days. Restore affects Local only and never automatically pushes.
- Recovery stores identifiers, metadata, order, conflict choices, and journal state; it does not duplicate media files or artwork caches.
- Background remote checks run only while Muses is active and network access is available, with a conservative freshness interval. They update Remote Shadow and badges only; no wake-up or unattended mutation is required for the first release.

## 5. Measured Apple Music Web baseline

Measurements taken on 2026-08-20 at a 1440×900 browser viewport establish the first token baseline:

| Element | Baseline |
|---|---:|
| Window-edge navigation inset | 8pt |
| Expanded navigation width | 244pt |
| Navigation corner radius | 20pt |
| Navigation item height | 34pt |
| Main content horizontal inset | 40pt |
| Page title | 34pt bold |
| Section title | 17–22pt semibold, depending on hierarchy |
| New editorial card | 540×309pt |
| Editorial horizontal gap | 20pt |
| Floating player ideal size | 668×56pt |
| Compact track row | approximately 55pt |
| Track artwork | approximately 40pt |

These are ideal measurements, not permission to clip at narrower widths. Components must define compression, wrapping, column-count, or alternate-layout behavior.

## 6. Native window and traffic lights

The main window uses a full-size content view with a transparent titlebar, but the three standard window buttons remain owned, positioned, and managed by `NSWindow`.

Required behavior:

- Never remove a standard window button from its AppKit superview.
- Never add a standard window button to a SwiftUI-hosting `NSView`.
- Never reposition the buttons in `layout()` or SwiftUI update callbacks.
- Configure the main `NSWindow` through one narrow, idempotent AppKit boundary.
- Do not use delayed retries, route-change retries, or recursive view-tree scans to hide titlebar controls.
- Expanded and collapsed sidebars reserve the same transparent top-leading clearance under the native controls.
- The sidebar glass may visually continue behind the titlebar, but interactive content must not collide with the native controls.
- Preserve native close, minimize, zoom, window dragging, restoration, keyboard focus, and accessibility behavior.

The minimum supported main-window layout is 840×600pt. Below the roomy layout threshold, content adapts in this order: reduce outer gaps, compress PlayerBar secondary controls, collapse the sidebar when requested, reduce page columns, and finally scroll. Content must not be silently clipped.

## 7. Shell and navigation

### 7.1 Sidebar

- Expanded width: 244pt; collapsed rail: 88pt; outer inset: 8pt; continuous 20pt corner.
- Search, Home, and Discover are the primary sidebar actions/destinations. Search opens the single floating Search window; Home and Discover navigate the main content.
- Library contains Songs, History, All Playlists, and individual playlists/imports.
- Inbox remains hidden from chrome.
- Radio is absent.
- Albums and Artists use the approved D2 identity model. Music Videos and Radio remain absent as destinations.
- Selected rows use Apple Music pink and a restrained neutral selection fill.
- Idle icons are semibold monochrome SF Symbols with at least a 28pt hit target.
- Profile remains at the bottom and opens Settings.

### 7.2 Main content

- Main content uses one consistent 40pt roomy inset, with responsive reduction only at constrained widths.
- Page titles and first content baselines align across destinations.
- Browsing cards do not use decorative glass.
- Tables use real separators, hover/selection states, keyboard focus, and context menus.
- Fixed-size shelves must become horizontal scrolling shelves or adaptive grids before they overflow.

## 8. Page contracts

### Home

- Reproduce the current signed-in YouTube Music Home information architecture: horizontal mood/activity chips; account-personalized quick-pick matrices; new releases; mixes and recommendations; editorial or seasonal shelves; and continuation shelves when supplied by the source snapshot.
- Preserve source section order, labels, media shapes, explicit actions such as Play all/More, and responsive shelf/matrix behavior. Apply Muses typography, spacing tokens, Apple Music pink semantics, native controls, and restrained chrome glass instead of copying YouTube branding or wrapping its webpage.
- Cards use real source artwork and endpoints. Video thumbnails are cropped or fitted according to the section layout contract; unavailable items use explicit placeholders rather than disappearing.
- Account-scoped cached content remains useful while refreshing. Loading, stale, partial, signed-out, private-capability-unavailable, and hard-error states are visually distinct.
- Guest Home remains composed from public YouTube discovery and local signals, with a low-pressure sign-in enhancement prompt rather than a blocking wall.

### Discover

- Landscape editorial cards follow the established Muses discovery composition.
- Best New Songs uses compact multi-column track rows where width permits and fewer columns when constrained.
- Additional discovery sections use square shelves.
- Use Apple Music Web's measured landscape editorial hero composition.

### Songs

- Use the approved D3 centered all-song card-deck stage and expandable content-pane full-list mode.
- Title A–Z is the immutable canonical/default Songs order; no manual reordering.
- Rows preserve play, context menu, queue, like, current-track, pointer, keyboard, and accessibility semantics.

### Playlists

- Overview uses square cards with title and ownership/source metadata.
- Detail uses the approved D3 centered card-deck stage and expandable full-list mode, defaulting to persisted Playlist Order.
- Imported YouTube playlists keep explicit resynchronization and deletion semantics.

### Search

- The single floating Search window owns the centered search field and all search state.
- Source scope distinguishes the YouTube Music/catalog search from the user's library when both are available.
- Empty search shows useful categories or suggestions, not two disconnected hints.
- Non-empty search groups results by meaningful type and preserves playback context.
- Main content never renders Search results or an empty Search placeholder.

### History

- History remains information-rich but visually neutral; artwork, typography, and Apple Music pink carry hierarchy instead of a competing blue/cyan visual system.
- History presents listening activity and recap summaries without duplicating a Recently Played track section or referring back to a removed Home shelf.

## 9. Player, Queue, Settings, and Now Playing

### PlayerBar

- Floating glass capsule, ideally 668×56pt, centered above content with a 20pt bottom margin.
- It overlays browsing content; scroll surfaces reserve sufficient bottom inset.
- It becomes responsive rather than clipping secondary controls.
- Transport, identity, progress, time, volume, lyrics, queue, expand, and YouTube video controls use a clear priority order.
- YouTube uses `YouTubeMark` and retains YouTube red.
- PlayerBar hides under the YouTube video overlay and fullscreen Now Playing.

### Queue

- Integrated trailing pane occupying the available content height.
- Not a detached rounded glass card.
- Preserve current collection queue, explicit Up Next, history, repeat, shuffle, reorder, and persistence semantics.
- Opening Now Playing closes Queue.

### Settings

- Centered native floating glass panel, approximately 520×560pt at the baseline size.
- Stable title and category navigation, readable grouped settings, and opaque fallback for Reduce Transparency or increased contrast.
- Dismiss via explicit close, Escape, or scrim where appropriate.
- Do not let colorful page artwork reduce settings contrast.
- Opening Settings dismisses transient Queue, lyrics-drawer, video, and add-link overlays. A retained Now Playing layer is disabled, hidden from accessibility, and must bypass its window-level key monitor until Settings closes.

### Now Playing

- Full-window expressive overlay; PlayerBar and Queue are hidden.
- Cover mode uses large square artwork. Vinyl mode uses circular artwork without a decorative disc rim.
- Lyrics occupy the right column at roomy widths and adapt below the breakpoint.
- A no-track invocation presents an intentional empty state or is disabled; it must not show a nearly blank lyrics page.

## 10. Visual system

- Typeface: system SF Pro.
- Page background: `#1F1F1F` dark and near-white light.
- Semantic accent: `#FA586A`.
- YouTube mark: YouTube red.
- Use one neutral gray family per appearance.
- Hairlines are subtle but visible; they are not fully transparent.
- Use native or centralized semantic glass roles for sidebar, PlayerBar, Settings, and compact chrome only.
- Nearby custom glass elements share a coherent container when the runtime supports native Liquid Glass.
- macOS 14/15 use adaptive system-material fallbacks.
- Reduce Transparency and increased contrast use an opaque semantic surface.
- No Sidra glow, generic card glass, arbitrary gradients, or decorative blue/cyan accents.

## 11. Accessibility, motion, and performance

- Every icon-only control has a localized accessibility label and help text.
- Preserve keyboard navigation, visible focus, application menus, complete track context menus, and native pointer behavior.
- Respect Reduce Motion in hover, matched geometry, automatic lyric scrolling, vinyl, spectrum, and overlay transitions.
- Vinyl rotation is elapsed-time based, not refresh-count based.
- Timeline and spectrum work stops when its surface is hidden or inactive.
- Large lists use lazy containers and immutable snapshots; do not traverse SwiftData relationships repeatedly in `body`.
- Artwork decoding, palette extraction, network work, and cache I/O remain outside `body` and are guarded by media identity.

## 12. Architecture and data boundaries

- `MusesApp` remains the composition root.
- `PlaybackService` remains the only UI/system playback facade.
- `YouTubeStreamEngine` remains the production playback engine.
- No parallel queue, playback, library, search, import, or persistence services are created in views.
- Visual reconstruction must not simplify mature queue/history behavior.
- V3 persistence follows the approved D1 snapshot, validation, and rollback contract.
- D2 catalog surfaces use stable YouTube identities and immutable value projections; rebuildable cache data remains separate from user truth.

## 13. Verification contract

Each phase requires focused tests plus rendered inspection. Final acceptance includes:

- 1440×900, 1224×768, and 840×600 windows.
- Expanded and collapsed sidebar with identical native traffic-light positions.
- Dark and light appearances.
- High contrast, Reduce Transparency, and Reduce Motion.
- Keyboard traversal, Escape behavior, focus rings, pointer hover, and VoiceOver labels.
- Home, Discover, the floating Search window, Songs, History, Playlists overview/detail, Queue, Settings, PlayerBar, and Now Playing.
- Scroll content is never hidden behind PlayerBar.
- No fixed-width content is clipped at the minimum window size.
- Existing playback, queue, history, import, and persistence tests pass except separately documented pre-existing failures.
- Visual decisions are evaluated from screenshots or the rendered app, not token tests alone.

## 14. Historical-document handling

Keep superseded specifications and plans as history. Their unchecked boxes are not an active roadmap. New implementation work must cite this specification; any future change to D1–D3 must amend this file or add a clearly linked successor before code changes begin.
