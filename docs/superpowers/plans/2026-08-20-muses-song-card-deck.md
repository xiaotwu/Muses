# Muses Songs / Playlist Card-Deck Implementation Plan

Status: approved for implementation on 2026-08-20.

## 1. Source of truth

- Product decisions: the current user decisions that replace the former split D3 header.
- Product specification: `docs/superpowers/specs/2026-08-20-muses-apple-music-web-reconstruction.md`, D3.
- Visual and motion reference: the polished Open Design project `Muses — Song Card Deck`, entry `muses-macos-prototype.html`.
- Production target: native macOS SwiftUI. The Open Design HTML is a validation reference, never a WebView implementation.

## 2. Required outcome

Songs and every user-playlist detail share one native collection page with two persistent presentation states:

1. A centered identity/actions region and virtualized fan-shaped portrait hero deck.
2. A content-pane full-list mode containing the complete native sortable table.

The sidebar and floating PlayerBar remain visible in both states. Songs keeps title A–Z canonical order. Playlists keep `PlaylistItem.order`. Visual table sorting never mutates either canonical sequence or playback context.

## 3. Interaction contract

### Deck

- Render about nine cards at roomy width and five at the 840×600 minimum, irrespective of collection size.
- Keep one focused canonical index shared by pointer drag, trackpad/wheel, chevrons, keyboard, and scrubber.
- Use velocity-aware projected drag distance followed by deterministic integer snapping.
- Hover opens the fan by about six percent; the hovered card lifts about 12pt, scales slightly, receives higher z-order and a restrained shadow, and neighboring cards yield a few points.
- Playing and focused are separate states. Playing uses a thin Apple Music pink outline and a small state mark, never glow.
- Every card retains the complete track context menu and an explicit accessibility value.

### Hero activation

- Call the existing collection `onPlay` closure immediately so `PlaybackService`, queue context, system media state, and PlayerBar update through the established path.
- Lock only the one-shot ceremony against duplicate activation.
- Animate a temporary duplicate from the selected card frame to the main-pane center in about 220ms.
- Dim/desaturate only the collection stage, then burn the duplicate inward for about 620ms using an irregular char edge, ember line, ash, and restrained sparks.
- Remove the duplicate, restore the stage, and let `currentTrack` mark the original card as playing.
- Reduce Motion uses an approximately 160ms opacity/scale acknowledgement with immediate playback and no particles.
- Table rows, Play All, Shuffle, context-menu playback, and other non-card paths never invoke the ceremony.

### Full-list mode

- A 44pt-or-larger chevron-up handle below the scrubber opens the table by click or a direction-locked upward gesture of at least 48pt.
- A mirrored handle closes by click/downward gesture; Escape also closes.
- Transition duration is 260–320ms ease-in-out with no bounce.
- Keep deck and table mounted so focus, table sorting, column customization, selection, and native table scroll position survive the round trip.

## 4. Architecture and file changes

### `Muses/Sources/Muses/Features/Shared/CollectionPage.swift`

- Replace the former leading-identity/trailing-rail composition with a two-state `ZStack`.
- Keep `CollectionTrackTable` native and mounted in both states.
- Route hero activation through the ceremony coordinator; continue routing table playback directly to `onPlay`.
- Own only page presentation and ceremony state. Do not create playback, queue, library, or persistence services.

### `Muses/Sources/Muses/Features/Shared/CollectionSongDeck.swift` (new)

- Add the focused-index deck, nearby-card projection, responsive fan geometry, hero card, custom scrubber, expansion handle, and localized accessibility semantics.
- Add one narrow `NSViewRepresentable` that observes scroll-wheel events only while the pointer is inside the deck. SwiftUI remains the source of truth.
- Use immutable `CollectionTrackRow` values and render only nearby rows.

### `Muses/Sources/Muses/Features/Shared/CollectionEmberCeremony.swift` (new)

- Add the temporary card duplicate and deterministic animatable burn mask/ember particle drawing.
- Keep its animation clock alive only during the one-shot ceremony.
- Do not mutate or delete track data.

### `Muses/Sources/Muses/App/AppleMusicTokens.swift`

- Replace obsolete landscape-rail geometry with semantic deck card, fan, scrubber, expansion, and ceremony metrics.
- Keep Apple Music pink and existing chrome geometry unchanged.

### `Muses/Sources/Muses/Features/Shared/MusesMotion.swift`

- Add named deck snap, list transition, card-center, burn, and Reduce Motion durations.

### `Muses/Sources/Muses/Features/Shared/CollectionTrackRow.swift`

- Keep canonical ordering unchanged.
- Add only pure presentation helpers needed for visible-index projection, snapping, or current-track matching when they improve testability.

### Call sites

- `SongsListView` and `PlaylistDetailView` keep their existing canonical snapshots and `playback.playTrack(...context:)` closures.
- No `PlaybackService`, `QueueService`, SwiftData schema, migration, or PlayerBar behavioral change is authorized by this plan.

## 5. Tests

- Songs remains deterministic title A–Z and filters unplayable rows.
- Playlist rows remain persisted Playlist Order.
- Wide/narrow deck projection yields the intended nearby-card counts and clamps first/last boundaries.
- Predicted drag snapping clamps and resolves to a canonical integer index.
- Expansion gesture accepts vertical threshold/direction and rejects horizontal deck movement.
- Table sorting leaves original rows/canonical indices untouched.
- Updated chrome tests assert portrait deck geometry instead of the superseded landscape rail.
- Source-level build catches SwiftUI/AppKit bridge lifecycle and Swift 6 actor issues.

## 6. Rendered verification

- Build and run through `./script/build_and_run.sh --verify` after focused tests pass.
- Inspect Songs and at least one playlist at 1440×900 and 840×600.
- Verify first/middle/last deck navigation, drag snap, trackpad/wheel, scrubber tooltip, hover lift, right-click menu, card burn, duplicate lock, PlayerBar update, expansion, table sort, table scroll preservation, down gesture, and Escape.
- Repeat the visual pass in dark/light, Reduce Motion, Reduce Transparency, and increased contrast where practical.
- Confirm content stays above the floating PlayerBar and cards/table remain keyboard and VoiceOver operable.

## 7. Non-goals and risk boundaries

- Do not alter audio engines, queue semantics, history, YouTube import ownership, persistence, signing, or packaging beyond what compilation requires.
- Do not restore Radio or any local-file workflow.
- Do not put glass on hero cards or the table.
- Do not keep animation timers alive while the ceremony is absent.
- Do not eagerly render every hero card for large playlists.
