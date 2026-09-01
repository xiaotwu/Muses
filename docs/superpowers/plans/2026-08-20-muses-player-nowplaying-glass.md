# Player chrome, fullscreen Now Playing, glass sidebars

**Goal:** Match the Apple Music player-bar cluster, make Now Playing a fullscreen artwork environment, glass both sidebars, fix station-card hover stealing, and put traffic lights in the sidebar corner with a collapse rail.

**Do not change:** PlaybackService engines, QueueService internals, SwiftData schema, OAuth keys.

## Layout

1. **PlayerBar** — left: shuffle / prev / filled play / next / repeat. Center: art + title + artist + elapsed/remaining. Right: lyrics, queue, YouTube, volume, expand. Keep the floating capsule (not a full-width dock). Hide the capsule while Now Playing is open.
2. **Now Playing** — covers the window (sidebar + content). Artwork gradient. Chevron back. Large square cover on the left with title/artist, seek, transport, volume under it. Lyrics on the right; current line uses accent. No duplicate dock.
3. **Sidebars** — left nav and queue use `musesGlass`; drop hard fills and header dividers.
4. **Station cards** — clip and `contentShape` to the square so a 200pt decode frame cannot steal the next cell’s hover.
5. **Traffic lights** — pin inside the sidebar’s top-leading corner; tighter pad so the wordmark sits closer. Collapsed state is a 56pt glass rail with lights + expand, not a blank titlebar strip.

## Files

- `AppleMusicTokens.swift` — policies
- `PlayerBar.swift` — transport cluster + layout
- `NowPlayingView.swift` — fullscreen chrome + under-cover transport
- `LyricsView.swift` — leading + accent current line in NP
- `RootView.swift` — hide dock, full overlay, collapsed rail
- `SidebarView.swift` — glass, collapse control, tighter lights
- `TrafficLightsPad.swift` — inset matching sidebar
- `QueueDrawerView.swift` — glass, no header divider
- `SongStationCard.swift` — clip overflow
- `ChromeLayoutTests.swift`

Verify: `swift test --no-parallel --filter ChromeLayoutTests`, then `make app`.
