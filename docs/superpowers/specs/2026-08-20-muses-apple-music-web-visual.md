# Muses — Apple Music Web visual system

- **Date:** 2026-08-20
- **Status:** Superseded by `2026-08-20-muses-apple-music-web-reconstruction.md`
- **Supersedes (UI chrome + visual language):** `2026-08-20-muses-sidra-chrome.md`
- **Does not supersede:** YouTube-native playback (`YouTubeStreamEngine` / yt-dlp), queue, OAuth, playlist Data API write-back, `2026-08-19-muses-youtube-native-redesign.md`

## 1. Goal

Restyle Muses as a native SwiftUI visual clone of the Apple Music Web Player (`music.apple.com`). Someone glancing at the window should read it as Apple Music Web: pink accent, SF Pro hierarchy, glass dock, Listen Now / New content density, persistent Library pane, content-area search, and an immersive Now Playing page.

Muses stays a YouTube-native macOS app. Do not wrap `music.apple.com` or `music.youtube.com` in a WebView. Do not add Radio. Do not change playback, queue, or import engines.

## 2. Confirmed decisions

| Topic | Choice |
|---|---|
| Fidelity | Visual language clone of `music.apple.com`, measured at implementation |
| Stack | Native SwiftUI only |
| Accent | Apple Music pink (start `#FA586A`, calibrate from live Web Player) |
| Glow | None. Sidra white bloom is removed |
| YouTube mark | Keeps its own red |
| Primary nav | Left pane: Search, Home, New (pink when selected). No Radio. No top-bar tabs |
| Library sidebar | Always visible on Home, New, and Library |
| Search | Real top-bar field; first non-empty query replaces main content |
| Settings | Content-slot account page, not a 680×520 System Settings sheet |
| Player | Floating capsule (live music.apple.com). YouTube video occupies the AirPlay slot |
| Now Playing | Content slot; large cover + title/artist under it; lyrics right; lyrics can fill the slot |
| Home / New | Listen Now / New layouts, YouTube discovery data |
| Playback / queue / OAuth / yt-dlp | Unchanged |

## 3. Visual system

Measure `music.apple.com` in both appearances at implementation and lock tokens in `BrandColors`. Until that measurement lands, use this starting palette.

### 3.1 Color

```
dark:
  background     #1F1F1F
  chrome         #1C1C1E
  surface        #2C2C2E
  textPrimary    #F5F5F7
  textSecondary  #A1A1A6
  accent         #FA586A
  youtubeRed     existing YouTubeMark red

light:
  background     #FFFFFF
  chrome         #F5F5F7
  surface        #E8E8ED
  textPrimary    #1D1D1F
  textSecondary  #6E6E73
  accent         #FA586A
```

`BrandColors.magenta` (and current white/black stand-ins `cyan` / `green` where they mean accent) resolve to `accent`, not to primary text.

Use accent for:

- Play fill on browsing cards (circular overlay)
- Scrubber elapsed fill and knob
- Selected Library sidebar item
- Now Playing / queue / songs current-row title
- Active lyric line
- Toggle / switch on state in Settings
- Text links that mean “play this” or “open this editorial”

Do **not** use accent for:

- Selected Home / New / Library top tab (bold primary text)
- Idle icons
- Page titles
- Body copy

YouTubeMark stays red. Never recolor it pink.

### 3.2 Type

Use the system SF Pro stack (`.system`). Do not introduce a custom display face.

| Role | Size | Weight |
|---|---|---|
| Page title (Home, New, Library destinations, Search, Account) | ~34pt | heavy / bold |
| Section title (rails, Settings groups) | ~22pt | semibold |
| Card title | ~13pt | semibold |
| Card subtitle / secondary | ~12pt | regular |
| Track row title | ~13pt | regular; semibold + accent when current |
| Dock title | ~13pt | semibold |
| Dock subtitle | ~11–12pt | regular, secondary |

### 3.3 Shape and density

- Album / playlist cards: continuous corner radius 6–8pt
- Dock artwork: 4–6pt
- Search field: capsule
- Play overlay on cards: circle, accent fill, white glyph
- Settings grouped lists: ~10pt continuous rounded groups on `surface`
- Library pane width: 232–260pt
- Top bar height: ~52pt
- Dock height: ~72pt
- Home rail card: square, ~160pt (Keep `MusicObjectMetrics` unless measurement says otherwise)
- Top Picks editorial cards: larger than rail cards; still square-cropped artwork, not 16:9 slots

### 3.4 Material

- Window fill: `background`
- Top bar and Library pane: `background` / `chrome`, not a floating capsule
- Dock: system material / Liquid Glass (`musesGlass`). Reduce Transparency or Increase Contrast → opaque `chrome` / `surface`
- Queue panel: opaque `chrome` with a hairline, not decorative glass on every row
- Browsing cards: no glass, no generic blur

### 3.5 Motion

- Card hover: 120–180ms ease, a few points of lift, circular Play fades in. No bounce.
- Playing Now Playing cover: slight scale and a soft drop shadow. No white glow.
- Vinyl (settings-only): circular spinning cover, no disc rim. Reduce Motion → static
- Playback-position and vinyl may animate. List rows and chrome must not sample those clocks.
- Reduce Motion: instant swap or opacity; no cover scale; hover Play may appear without lift

## 4. Shell

Hidden titlebar, `fullSizeContentView`. One chrome row. No spare title strip.

```
┌ traffic lights | Muses | Home  New  Library        [search field] [avatar] ┐
├ Library pane (~232–260pt)                          ┬ content              ┤
│  Library: Recently, Songs, Playlists, History,     │                      │
│           Inbox                                    │                      │
│  Playlists: All Playlists + playlist/import rows   │                      │
├ art  title / artist  | shuffle prev play next rpt  | lyrics queue YT vol  ┤
│                      | ------ long scrubber ------ |                      │
```

The dock spans the full window width, including under the Library pane. The YouTube video overlay is the only surface that hides the dock.

### 4.1 Top bar

- Leading: `TrafficLightsPad`, then the Muses wordmark (not a second window title)
- Center-leading: text tabs **Home**, **New**, **Library**
- Selected tab: primary text, semibold. Unselected: secondary, ~70% opacity. No pink, no glow
- Trailing: real `TextField` (not a button that posts a notification), then avatar
- Avatar opens the Account / Settings content page
- Clicking Library while already in a Library destination leaves the current destination. Clicking Library from Home / New / Search / Account / Now Playing restores the last Library destination, defaulting to Recently

### 4.2 Library pane

Always mounted. Home and New no longer go full-width.

Items stay:

- Recently, Songs, Playlists (All Playlists + inline playlist and YouTube-import rows), History, Inbox
- No Albums destination, no Artists destination, no Radio

Selected row uses accent. Idle rows use primary text and monochrome SF Symbols (semibold, hit target ≥ 28pt). Collapse, if present, lives in this pane.

Clicking a Library row while Home or New is selected switches the top tab to Library and shows that destination. The reverse is also true: Home / New top tabs show those pages without changing the sidebar highlight until a Library row is clicked.

Sidebar highlight rules:

- On Home or New, no Library row is required to appear selected
- On a Library destination, that row is selected
- Playlist / import rows select as they do today

### 4.3 Player dock

Replace any remaining capsule thinking. Full width, ~72pt, material over the window.

**Left:** artwork (~48pt) + title / artist. Click artwork or title opens Now Playing.

**Center:** shuffle, previous, play (larger), next, repeat. Dock play/pause is a primary-colored circle (white on dark, black on light), matching Apple Music Web — not pink. Beneath the controls, a long scrubber with elapsed and remaining (`−m:ss`). Scrubber fill is accent.

**Right:** lyrics, queue, YouTube video (pauses audio; optional resume), volume icon with popover slider. The video control sits where Apple Music puts AirPlay. It uses `YouTubeMark` or the existing video affordance, not a pink triangle.

Hide the dock only under the YouTube video overlay.

Progress lives in the center scrubber, not as a hairline across the whole bar.

## 5. Home and New

Page titles stay **Home** and **New** (~34pt heavy). Do not retitle Home to Listen Now.

Artwork is square. YouTube 16:9 thumbnails stay center-cropped. Click and context-menu behavior is unchanged. Focus mode still suppresses discovery.

Shared card chrome:

- Radius 6–8pt
- Hover: lift + bottom-trailing circular accent Play
- Current playing card keeps Play visible
- No glass on cards, no idle glow

### 5.1 Home (Listen Now layout)

1. **Top Picks** — two or three large editorial cards in a row. Artwork + title overlay + Play. Data: existing hero, Mixed for you, or the first `HomeDiscoveryService` section, in that preference order. If fewer than two items exist, show what we have; do not fabricate cards.
2. **Recently Played** — existing playback-history rail, square cards, horizontal scroll.
3. **Remaining discovery sections** — Apple Music rails: ~22pt section title, square cards, title + subtitle. `HomeDiscoveryService` keeps providing titles and items.
4. **Your Playlists** — imported / local playlists as a rail when that set is non-empty and not already represented by a discovery section.

Infinite scroll / `loadMore` on discovery stays. Per-section failure stays (one dead rail does not blank the page).

### 5.2 New

Apple Music New layout on existing New data:

- One large featured editorial slot at the top
- Latest / new-content rails underneath

No Apple catalog. No Coming Soon unless New already has that data.

## 6. Now Playing

Fills the content slot: below the top bar, above the dock, to the right of the Library pane. It does not cover chrome and does not duplicate shuffle / play / scrubber.

Default layout:

- Left: large square cover (size bounded by the slot; keep it the visual hero)
- Directly under the cover: title, then artist (and album if the snapshot has it)
- Right: scrolling lyrics. Current line accent; surrounding lines secondary
- Close control in the slot. Esc dismisses. Opening Now Playing closes the queue panel

Vinyl remains settings-only: circular cover, no disc rim.

Playing cover: slight scale + soft shadow. Reduce Motion: no scale.

### 6.1 Lyrics focus

Dock lyrics button:

- If Now Playing is closed → open Now Playing with lyrics focused
- If Now Playing is open → toggle lyrics filling the content slot (cover shrinks or hides)

Existing `LyricsDrawerView` as a separate drawer is retired from this interaction. Lyrics live in Now Playing.

### 6.2 Queue

Dock queue button toggles a trailing **Playing Next** panel above the dock (existing `QueueDrawerView` restyled). Current track title uses accent. Reorder, Up Next, history semantics are unchanged.

Opening Now Playing still closes the queue panel. Opening the queue does not have to close Now Playing unless the panel would cover the lyrics column unusably; prefer overlaying the right side.

### 6.3 YouTube video overlay

Unchanged behavior: on-demand overlay, pauses audio, optional resume. It is not the Now Playing cover and not a bottom well.

## 7. Search

The top bar hosts a real `TextField`.

- Focus alone does not replace the current page
- The first non-empty character replaces the main content with the search page
- Clearing the field or pressing Esc restores the page that was showing before search
- Top-tab selection, Library pane, and dock stay put
- Existing Focus Search shortcut focuses the top-bar field

Results use `GlobalSearchService`. Layout:

- **Top Result** — one large card when the service can pick a best hit
- **Songs / Playlists / other existing result types** — compact rows: square art, title, subtitle, duration
- Current playing row title uses accent

Play / open / context-menu behavior is unchanged. Empty, offline, and yt-dlp-unconfigured states keep current copy, restyled.

## 8. Library destinations and detail

Information architecture is unchanged. Visual language matches Apple Music lists.

- **Songs, Recently, History, Inbox:** compact track rows, current title in accent, existing context menus
- **Playlists overview:** square tiles / list consistent with Apple Music Library playlists
- **Playlist detail and YouTube import detail:** large square header artwork, accent Play and Shuffle, then a track table. Lazy snapshots stay mandatory for large lists

No Albums or Artists browse destinations.

## 9. Settings (Account page)

Avatar still opens Settings. Settings is no longer a floating 680×520 System Settings clone.

It occupies the main content slot (sidebar and dock remain):

1. Page title ~34pt (`tr("Settings", "设置")`). The layout is an Apple Music account page, not a System Settings window.
2. Circular avatar, YouTube account name or signed-out prompt, Connect / Sign out
3. Grouped rows for existing categories: General, Playback, Quality, Appearance, YouTube, Lyrics, Desktop, Updates, About
4. Selecting a row shows that category’s current form as a detail in the same slot (rounded grouped lists, accent switches)
5. Esc or an explicit Back control returns to the previous browse page
6. `initialSettingsCategory` deep links still open the matching detail

yt-dlp configuration wizard remains under YouTube. Do not drop categories.

## 10. What stays Muses

| Muses-specific | Where it lives |
|---|---|
| YouTubeMark | Track rows, import rows, video control |
| YouTube video overlay | Dock trailing cluster |
| Import / Inbox | Library pane + existing sheets |
| Focus / Audio nerd | Application menu and existing panels; token pass only |
| Language `tr(...)` | All user-visible strings |

## 11. Architecture and files

`MusesApp` remains the composition root. No parallel playback, library, search, or persistence services.

Primary UI touch points (expected, not an exhaustive diff):

- `BrandColors` in `RootView.swift` — restore real accent; stop mapping magenta to white/black
- `AppTopBar` — real search field, tab chrome without glow
- `RootView` — always-on sidebar; search as content; Settings as content; Now Playing layout
- `SidebarView` — visible for every top tab; selected row uses accent
- `PlayerBar` — accent play/scrubber; YouTube in AirPlay slot; lyrics opens Now Playing
- `HomeView` / `NewView` — Listen Now / New layouts
- `NowPlayingView` / `LyricsView` / `LyricsDrawerView` — lyrics in NP; drawer interaction retired
- `GlobalSearchView` — content page, Top Result + groups
- `SettingsSheet` — content-slot account page
- Playlist / songs / history / inbox / queue rows — list language + accent current state
- `ChromeLayoutTests` and related UI tests — update contracts
- `AGENTS.md` — chrome, color, glow, sidebar, Settings, Now Playing clauses

Do not opportunistically refactor `PlaybackService`, `YouTubeStreamEngine`, `QueueService`, `NowPlayingManager`, SwiftData schema, OAuth, or caches during this visual pass.

## 12. Documentation impact

This spec is the chrome and visual-language source of truth.

`AGENTS.md` must be updated in the same body of work so durable agent rules no longer say:

- Library sidebar only while Library is selected
- Pure black / white with no pink
- Restrained white glow on selected tab / playing cover / current row
- Settings as a sheet implied by current chrome copy
- Home / New full-width

`2026-08-20-muses-sidra-chrome.md` is superseded for UI chrome and color. Keep it as history.

`2026-08-19-muses-youtube-native-redesign.md` remains the playback and library source of truth.

## 13. Out of scope

- WKWebView chrome or wrapping Apple Music / YouTube Music
- Radio tab, Listen Now label on the Home tab, Apple catalog
- Changing `PlaybackService`, engines, queue persistence, OAuth scopes, playlist write-back
- Dropping SwiftData `Album` / `Artist` / `ScanRoot` tables
- Restoring local-file scanning or a bottom video well
- Inventing AirPlay
- Rewriting Focus / Audio nerd information architecture

## 14. Verification

Visual work is judged in the rendered app against `music.apple.com` at the same size and appearance.

- Window 1440pt-class, dark and light
- One top chrome row; traffic lights inside it
- Library pane present on Home, New, and Library
- Dock full width; identity / transport / extras still parse near 900pt
- Home: Top Picks + rails, square crops, accent Play on hover
- New: featured slot + rails
- Search: type in the top field → content search page; Esc restores
- Now Playing: dock visible, no second transport, lyrics right, lyrics-focus toggle
- Account page from avatar; Esc returns
- Dark: near-black background; play/progress/selected-row/sidebar-selection measure as pink, not white
- Light: inverse neutrals, same pink
- YouTubeMark still red
- No Sidra white glow on tabs or idle cards
- Keyboard, VoiceOver labels, Reduce Motion, Reduce Transparency keep their meaning
- Existing playback, queue, search, and import tests still pass
- `ChromeLayoutTests` updated to the new shell contracts

## 15. Implementation note

This is one design system, shipped in SwiftUI. Sequencing inside implementation (tokens and shell first, then Home/New, Now Playing, search, Account, remaining lists) is an execution detail, not a different visual target. Do not leave a long-lived Sidra/AM hybrid (white glow + pink, or full-width Home with an AM dock) as the accepted state.
