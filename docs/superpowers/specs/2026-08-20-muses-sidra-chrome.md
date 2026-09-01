# Muses — Sidra / Apple Music Web chrome

- **Date:** 2026-08-20
- **Status:** Superseded by `2026-08-20-muses-apple-music-web-visual.md` (chrome + visual language)
- **Supersedes (UI chrome only):** floating 700×54 capsule; traffic lights in the left sidebar; no top navigation bar
- **Does not supersede:** YouTube-native playback (`YouTubeStreamEngine` / yt-dlp), queue, OAuth, playlist write-back

## 1. Goal

Restyle Muses globally to the **Sidra / Apple Music Web Player shell**: one top bar, a Library-only sidebar, full-bleed content, and a full-width bottom player. Visual language is **pure black / pure white with restrained glow**, not Apple Music pink.

Sidra is an Electron wrapper around `music.apple.com`. Muses stays a native SwiftUI app. Borrow layout, density, and chrome — do not wrap YouTube Music in a WebView.

## 2. Confirmed decisions

| Topic | Choice |
|---|---|
| Shell | Web Player: top nav + full-width docked player |
| Top tabs | Home / New / Library. No Radio. |
| Traffic lights | Embedded in the same top-bar row (hidden system titlebar) |
| Library sidebar | Only while Library is selected |
| Search | Top-bar field; existing overlay, not a sidebar row |
| Profile | Top-bar avatar; click opens Settings only |
| Player | Full-width dock, always visible (including Now Playing) |
| Now Playing | Cover + lyrics in the content slot; **no second transport** |
| Color | Pure black / pure white. No pink accent. YouTube mark keeps its own red. |
| Glow | Restrained: playing cover, current row, selected top-tab only |
| Icons | Stroke-style, heavier, high contrast on **top bar + Library sidebar + player**. macOS application menu stays text. |

## 3. Shell

```
┌ traffic lights | Muses | Home  New  Library | search field | avatar ┐
├ Library only: Recently / Songs / Playlists / History / Inbox + lists ┬ content ┤
└ art+title | shuffle  prev  play  next  repeat + long scrubber | lyrics queue YT volume ┘
```

### Top bar

- Hidden titlebar, `fullSizeContentView`. One row, ~52pt.
- Leading: `TrafficLightsPad`, then Muses wordmark (not a second title).
- Center-leading: text tabs **Home**, **New**, **Library**. Selected tab uses primary text + slight glow; others secondary.
- Trailing: rounded search field (focus posts `.musesFocusSearch`), then avatar (opens Settings).
- No extra empty title strip.

### Library sidebar

- Visible only when the Library tab is selected.
- Width ~232pt. Items: Recently, Songs, Playlists (All Playlists + inline playlist/import rows), History, Inbox.
- Home and New use the full content width.
- Collapse control is optional; if present it lives in this pane, not a second titlebar.

### Content

- Home / New / Library-detail fill the remaining rectangle between top bar and player dock.
- Bottom padding must clear the dock (~72pt) so the last rail is not hidden.
- Home keeps YouTube Music-like rails (Listen again, Mixed for you, Quick picks, Charts, …). Hero + horizontal cards.

### Player dock (persistent)

Replace the floating 700×54 capsule.

- Full window width, ~64pt, glass/material over black, not an opaque black pill floating in the content.
- **Left:** 34pt square artwork + title / `artist — album`. Click artwork or title opens Now Playing.
- **Center:** shuffle, previous, play (larger), next, repeat. Beneath them a long scrubber with elapsed and remaining (`−m:ss`).
- **Right:** lyrics, queue, YouTube video (pauses audio), volume **icon** (popover slider).
- Progress is the center scrubber, not a hairline across the whole bar.
- Hide only under the YouTube video overlay.

### Now Playing

- Overlay fills the content slot (below top bar, above the dock).
- Left: large square cover (vinyl = circle, settings-only, no disc rim). Slight scale-up while playing.
- Right: lyrics.
- Close (× / Esc) dismisses. Opening NP closes queue and lyrics drawers.
- Do not duplicate shuffle/play/scrubber here.

## 4. Color and glow

```
background   #000000 (dark) / #FFFFFF (light)
surface      #26262B (dark) / #EBEBED (light)   // cards, dock fallback
textPrimary  #FFFFFF / #000000
textSecondary  ~65% white / ~45% black
accent       same as textPrimary (no pink, no extra brand hue)
glow         white bloom in dark, black bloom in light
```

- Selected / playing affordances use `textPrimary` plus `glow` (radius ~2.5, existing helper).
- Do not glow idle browsing cards, list rows, or every icon.
- Reduce Transparency: opaque surface, no glow.
- Reduce Motion: no cover scale; glow may remain as a static shadow.

`BrandColors.magenta` / `cyan` already resolve to white/black. Keep that mapping. Stop introducing `#FA586A`.

## 5. Icons

Sidra injects 20×20, 1.5pt stroke, round cap/join, idle 70% opacity, hover to full primary.

Apply that language with SF Symbols (no new icon font):

- Weight: `.semibold` or `.medium` at 13–15pt, not ultra-thin.
- Hit target ≥ 28pt.
- Player play/pause ~36pt.
- Library and top-bar icons must remain legible on pure black; avoid low-contrast hierarchical rendering as the only treatment.
- Application menu (`MusesApp.commands`) stays labels + shortcuts.

## 6. Out of scope

- Wrapping `music.youtube.com` or `music.apple.com` in WKWebView.
- Changing `PlaybackService` / yt-dlp / OAuth scopes / playlist Data API write-back.
- Dropping SwiftData `Album` / `Artist` tables.
- Inventing a Radio tab.
- macOS menu-bar iconography.

## 7. Verification

- Window: one chrome row; lights inside it; no spare title strip.
- Home/New: no Library sidebar. Library: sidebar present.
- Player: full width at all window sizes ≥ 1000pt; identity / transport / extras still parse at ~900pt.
- Now Playing: dock still visible; no second transport.
- Dark: backgrounds measure near 0,0,0; selected tab/play icon is white with a small bloom.
- Light: inverse.
- Keyboard, VoiceOver labels, Reduce Motion / Reduce Transparency unchanged in meaning.
