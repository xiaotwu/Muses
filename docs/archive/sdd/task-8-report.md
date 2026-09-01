# Task 8 Report: Hover Play, now-playing identity, row selection

## Status

**DONE**

## Summary

Hover Play sits on artwork. `NowPlayingMark` is the only object-level playback reader (`track?.id` + `isPlaying`, never `position`). Album/artist collection identity is parent-cached via `library.track(by:)` on track-id change. Songs list keeps `playsOnDoubleClick` and `List(selection:)`. `swift test --no-parallel`: **408 tests / 70 suites passed**.

## Changes

### Created

- `MusesMotion.swift` — verbatim tokens: hover 0.15, overlay 0.20, drawer 0.25, nowPlayingMorph 0.32; `hoverAnimation` / `morphAnimation` nil under Reduce Motion.
- `HoverPlayButton.swift` — 30pt circular `play.fill`, `BrandColors.textPrimary`, dim scrim (stronger when Reduce Transparency). `musesGlass(in: Circle())` as chrome on the object. Accessibility `tr("Play", "播放")`. Action → `onPlay`.
- `NowPlayingMark.swift` — `itemID: UUID`; `speaker.wave.2` while playing, `play.fill` when current but paused. Does not read `position`. Does not resolve album/artist IDs.

### Objects

- **Album** `.browse`: hover Play → `onPlay`; click elsewhere → `onSelect`. `.play`: both → `onPlay`. Lift 4pt / 150ms easeOut when `showsHoverPlay` and not Reduce Motion. `nowPlayingID` hosts `NowPlayingMark` for `.play` rails (snap id compared inside the mark, not the parent `ForEach`). `isNowPlaying` still shows `speaker.wave.2` for parent-cached collection identity.
- **Artist**: hover Play → `onPlay`; click → `onSelect`. Same lift rules.
- **Hero**: hover Play on the 240pt art → `onPlay`; art/title still `onOpen`. Lift on the cover only.
- **Song**: hover Play on the 44pt art when hovered **or** selected. **No lift.** `nowPlayingID` → `NowPlayingMark` beside the title. `playsOnDoubleClick` unchanged.

### Parent-cached IDs

`playingAlbumID` / `playingArtistID` + `refreshPlayingCollection()` on `.onAppear` and `.onChange(of: playback.state.track?.id)`:

- `HomeView`, `LibraryView`, `ArtistsView`, `ArtistDetailView`, `NewView`, `PinsView`, `RecentlyView`

Browse albums get `isNowPlaying: album.id == playingAlbumID`. Artists get `artist.id == playingArtistID`. Derived cards use `localAlbumID` / `localArtistID`. `.play` rails (Recently Played, New situational) pass `nowPlayingID: snap.id`.

### `showsHoverPlay: true`

Home / New / Library / Artists / album-artist-playlist-import detail / Pins / Recently / Playlists / Liked / derived browse. Playlist and YouTube-import rows keep `showsPlayButton`.

## Not done (out of scope)

- PlayerBar ↔ Now Playing matched geometry (Task 9).
- Engine / `PlaybackService` / `NowPlayingManager` edits.
- `playsOnDoubleClick` on Songs list was not undone.
- Play-context arrays were not changed.

## Verification

| Check | Result |
|---|---|
| `swift test --no-parallel` | PASS — 408 tests, 70 suites, 14.347s |
| `NowPlayingMark` reads `position` | no |
| Object-level `@Environment(PlaybackService)` | only `NowPlayingMark` |
| Parent `ForEach` reads `playback.state` | no; `.play` rails pass snap id |
| Songs `playsOnDoubleClick: true` | kept |
| `List(selection: $selectedSongID)` + Return | kept; `onSelect` still sets the binding |
| Glass on cards | no; glass only on `HoverPlayButton` chrome |

No rendered hover/click screenshots (Task 10).

## Commit

- `1fd47be` — feat: hover Play, now-playing identity, and song-row selection

20 files, +338 / −32, `Muses/Sources/Muses/Features` only.

## Self-review

- **Completeness:** Steps 1–7 done. Motion tokens, HoverPlay, NowPlayingMark, parent cache, hover wiring, Songs selection, tests, commit.
- **Quality:** Collection identity is one `library.track(by:)` per surface. Tiny mark views own play/pause glyphs. Song rows never lift.
- **Discipline:** No engine, schema, PlayerBar morph, or play-context changes.
- **Testing:** Full suite green.

## Concerns

1. **No rendered smoke.** Hover Play, lift, album click-vs-Play, playing mark, and Songs click-select / double-click-play were not click-tested in the running app (same AX / Screen Recording block as Tasks 3 and 7). Defer to Task 10.
2. **Nested Button.** `HoverPlayButton` is an overlay on an album/artist/hero `Button`. Inner control should win on macOS; not render-verified. Song rows use tap gestures, so Play there is cleaner.
3. **`.musesGlass(role: .floatingControl)` does not exist.** Closest API is `musesGlass(in: Circle())` plus a dim scrim. Reduce Transparency uses a denser scrim and the glass modifier’s opaque fallback.
4. **`library.track(by:)` uses a fresh `ModelContext`.** Same pattern as PlayerBar “Show in Album.” Relationship IDs are read immediately; if a future SwiftData change drops faults after context dealloc, collection marks would go blank without crashing.
5. **30pt Play on 44pt song art** covers most of the thumbnail when hovered/selected. Spec range 28–32pt; intentional.
6. **`playingArtistID` is stored on album-only surfaces** (Home, Library, Pins, Recently, New, Artist detail) per the brief snippet and only *read* on `ArtistsView`. Harmless extra state.
