# Task 6 Report: Shared music-object types (no hover, no swap)

## Status

**DONE**

## Summary

Four Shared primitives plus metrics landed under `Features/Shared/`. Call sites are untouched. `showsHoverPlay` defaults `false` and is unread. No `onHover`, no glass, no playback reads, no `.trackContextMenu`. Every `ArtworkView` passes an explicit `targetSize`. `swift build --target Muses` succeeded.

## Changes

### `MusicObjectMetrics.swift`

Verbatim brief constants:

| Token | Value |
|---|---|
| `albumRail` | 160 |
| `albumGrid` | 200 |
| `albumHero` | 240 |
| `artistGrid` | 200 |
| `artistHeader` | 180 |
| `songArtMin` | 44 |
| `songArtMax` | 48 |
| `playerBarArt` | 52 |
| `albumCornerRail` | 8 |
| `albumCornerHero` | 12 |
| `hoverLift` | 4 |
| `hoverDuration` | 0.15 |

### `AlbumObject.swift`

`AlbumObjectRole` `.browse` / `.play`. `AlbumObjectView` matches the brief body: role switch on click, `ArtworkView(..., targetSize: size)`, now-playing `speaker.wave.2`, no glass/ring. `showsHoverPlay` stored, unused.

### `ArtistObject.swift`

Circle `ArtworkView` (`clipCircle: true`, `targetSize: size`). Click → `onSelect` only. `onPlay` and `showsHoverPlay` stored for Task 8, unused.

### `SongObject.swift`

Spec accessories: `albumTitle`, `durationLabel`, `indexLabel`, `isLossless`, `showLocalBadge`, `isLiked` / `onToggleLike`, `onRemove`, `onQueue`, `onInbox`, `onOverflow`. Art `MusicObjectMetrics.songArtMin` (44), 4pt corner.

- Tap → `onSelect()` only. `onPlay` unused. No auto-play.
- Selected: `BrandColors.surface`, 6pt corner.
- Now-playing: `speaker.wave.2` + `BrandColors.textPrimary` title.
- Hi-Res: `tr("Hi-Res", "Hi-Res")` when `isLossless`.
- Local: `tr("Local", "本地")` when `showLocalBadge`.
- Heart only when `isLiked != nil`.
- Does not read `playback`. No `.trackContextMenu`.

### `HeroObject.swift`

Brief signature `HeroObjectView(title:subtitle:metadata:artwork:gradient:onOpen:onPlay:)`:

- Art `albumHero` 240, `albumCornerHero` 12.
- Art/title → `onOpen`. Play `tr("Play", "播放")` → `onPlay`.
- `LinearGradient` behind when `gradient` is non-empty.
- `FEATURED` / `推荐` eyebrow hardcoded to match today’s Home hero block.

Spec’s `eyebrow` / `year` parameters were not used; the brief signature won.

## Not done (out of scope)

- No call-site swap (Task 7).
- No `onHover` / hover Play (Task 8).
- Old cards (`AlbumCard`, `DiscoveryCard`, `SongCompactRow`, …) kept.

## Verification

| Check | Result |
|---|---|
| `swift build --target Muses` | PASS (2.32s incremental; 5 new files compiled) |
| `rg 'onHover\|hoverEffect\|musesGlass\|playback\|trackContextMenu\|NSImage'` on the five files | no hits |
| `showsHoverPlay` default | `false`; declaration only |
| Call-site references to the new types | none outside the five files |
| Explicit `ArtworkView` `targetSize` | album `size`, artist `size`, song `songArtMin`, hero `albumHero` |

No unit tests (plan: build only). No rendered screenshot.

## Commit

- `8ac845a` — feat: Album, Artist, Song, and Hero object primitives

5 files, +322, `Muses/Sources/Muses/Features/Shared/` only.

## Self-review

- **Completeness:** Steps 1–6 done. Metrics and Album/Artist bodies match the brief. Song/Hero implement every listed accessory/action.
- **Quality:** Display-only via `ArtworkView`. No decode, glass, hover, or engine reads.
- **Discipline:** New Shared files only. No Task 7/8 work.
- **Testing:** App-target compile only.

## Concerns

1. **Hero brief vs spec.** Spec §5.3.6 is `eyebrow` / `year` and says the gradient stays on `HomeView`. Brief is `metadata` / `gradient` and “artwork gradient behind.” Implemented the brief. Task 7 should pass `heroGradient` into `gradient` and year as `metadata` (`String(year)`). `FEATURED` is inside the primitive, not a parameter.
2. **Song `onPlay` unused.** Playlist / YouTube rows today have an in-row Play button. After Task 7’s swap, play will be call-site `onSelect` wiring or Task 8 hover until something shows a Play control. Intentional for this task.
3. **Artist `onPlay` unused.** Same as the brief body (click is `onSelect`).
4. **No rendered check.** Types are unhosted; visual judgment waits for Task 7.
