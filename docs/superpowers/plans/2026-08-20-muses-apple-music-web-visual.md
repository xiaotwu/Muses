# Apple Music Web Visual System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle Muses in native SwiftUI to match Apple Music Web Player chrome, tokens, Home/New, Now Playing, search, and Account settings while keeping YouTube playback and IA.

**Architecture:** Extract testable chrome/token policies (`AppleMusicTokens`, `LibraryChromePolicy`, `SearchChromePolicy`, `DockLyricsPolicy`, `TopPicksResolver`). Apply them through existing `BrandColors`, `RootView`, `AppTopBar`, `SidebarView`, `PlayerBar`, `HomeView`, `NewView`, `GlobalSearchView`, `SettingsSheet`, and `NowPlayingView`. Do not add a WebView shell.

**Tech Stack:** Swift 6 / SwiftUI / Swift Testing / macOS 14+ Apple Silicon. Tests: `swift test --no-parallel --filter ChromeLayoutTests` during tasks; `make test` at the end. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-20-muses-apple-music-web-visual.md`

## Global Constraints

- Platform: **macOS 14+**, Apple Silicon. Bundle id `com.muses.app`.
- User-visible strings go through `tr("English", "中文")`. Source comments and identifiers stay English.
- `PlaybackService` is the only playback facade. Do **not** edit `PlaybackService`, `YouTubeStreamEngine`, `QueueService` internals, OAuth, SwiftData schema, or yt-dlp.
- Accent is Apple Music `--keyColor` **`#FA586A`** (measured 2026-08-20 on `music.apple.com`). Dock play/pause is primary-colored, not pink. Card Play is pink. YouTubeMark stays red.
- No Sidra white glow on tabs, glyphs, or playing cover. Playing cover uses a soft drop shadow.
- Library sidebar is always visible unless the user collapsed it. Home / New are not full-width.
- Search occupies main content after the first non-empty character. Settings is a content-slot Account page.
- Work in the current dirty worktree (Sidra chrome is already uncommitted). Do not stash unrelated files. Commit only files this task touches. Keep `Agents.md` byte-identical to `AGENTS.md` after any agent-doc edit.
- Honor Reduce Motion and Reduce Transparency. Hit targets stay ≥ 28pt.
- Live AM Web (Aug 2026) uses a left nav of Search/Home/New/Radio and 16:9 editorial heroes. Muses still uses Home/New/Library + persistent Library pane + square YouTube crops, per spec. Tokens and density come from live CSS, not that IA.

## File Structure

```
Muses/Sources/Muses/App/AppleMusicTokens.swift          Tasks 1–2 (new)
Muses/Sources/Muses/App/RootView.swift                  BrandColors + shell
Muses/Sources/Muses/App/GlassSurface.swift              glow unused on chrome
Muses/Sources/Muses/Features/Shared/ChromeGlyph.swift   selected = accent, no glow
Muses/Sources/Muses/Features/Shared/HoverPlayButton.swift  pink fill
Muses/Sources/Muses/Features/Shared/HeroObject.swift    Top Picks cards
Muses/Sources/Muses/Features/AppTopBar.swift            real search field
Muses/Sources/Muses/Features/SidebarView.swift          always-on pane
Muses/Sources/Muses/Features/PlayerBar.swift            scrubber accent, lyrics policy
Muses/Sources/Muses/Features/HomeView.swift             Listen Now layout
Muses/Sources/Muses/Features/NewView.swift              New layout + 34pt title
Muses/Sources/Muses/Features/Search/GlobalSearchView.swift  content page
Muses/Sources/Muses/Features/Settings/SettingsSheet.swift   Account page
Muses/Sources/Muses/Features/NowPlaying/NowPlayingView.swift  shadow, lyrics focus
Muses/Sources/Muses/Features/NowPlaying/LyricsDrawerView.swift  unused by dock
Muses/Tests/MusesTests/ChromeLayoutTests.swift          all policy tests
AGENTS.md / Agents.md                                   already aligned; Task 1 verifies
docs/superpowers/specs/2026-08-20-muses-apple-music-web-visual.md  lock measured dark page #1F1F1F
```

---

### Task 1: Lock measured Apple Music tokens

**Files:**
- Create: `Muses/Sources/Muses/App/AppleMusicTokens.swift`
- Modify: `Muses/Sources/Muses/App/RootView.swift` (`BrandColors` at ~542)
- Modify: `Muses/Tests/MusesTests/ChromeLayoutTests.swift`
- Modify: `docs/superpowers/specs/2026-08-20-muses-apple-music-web-visual.md` (dark background `#1F1F1F`)

**Interfaces:**
- Consumes: live CSS `--keyColor: #fa586a`, `body` `rgb(31,31,31)`, h1 `34px/700`
- Produces: `AppleMusicTokens.keyColorHex`, `keyColorRGB`, `darkPageRGB`, `pageTitleSize`, `sectionTitleSize`, `sidebarWidth`, `cardCorner`. `BrandColors.magenta` / `cyan` / `green` resolve to key color. `BrandColors.background` dark = `#1F1F1F`.

- [ ] **Step 1: Write the failing token tests**

Add to `ChromeLayoutTests.swift`:

```swift
@Test("Apple Music key color is FA586A")
func appleMusicKeyColor() {
    #expect(AppleMusicTokens.keyColorHex == "FA586A")
    #expect(abs(AppleMusicTokens.keyColorRGB.r - 250.0 / 255.0) < 0.0001)
    #expect(abs(AppleMusicTokens.keyColorRGB.g - 88.0 / 255.0) < 0.0001)
    #expect(abs(AppleMusicTokens.keyColorRGB.b - 106.0 / 255.0) < 0.0001)
}

@Test("dark page background is measured AM Web 1F1F1F")
func darkPageBackground() {
    #expect(abs(AppleMusicTokens.darkPageRGB.r - 31.0 / 255.0) < 0.0001)
    #expect(AppleMusicTokens.pageTitleSize == 34)
    #expect(AppleMusicTokens.sectionTitleSize == 22)
    #expect(AppleMusicTokens.sidebarWidth >= 232 && AppleMusicTokens.sidebarWidth <= 260)
    #expect(AppleMusicTokens.cardCorner == 8)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --no-parallel --filter ChromeLayoutTests.appleMusicKeyColor`

Expected: FAIL, `AppleMusicTokens` not found.

- [ ] **Step 3: Add tokens and point BrandColors at them**

Create `AppleMusicTokens.swift`:

```swift
import CoreGraphics
import Foundation

enum AppleMusicTokens {
    static let keyColorHex = "FA586A"
    static let keyColorRGB = (r: 250.0 / 255.0, g: 88.0 / 255.0, b: 106.0 / 255.0)
    static let darkPageRGB = (r: 31.0 / 255.0, g: 31.0 / 255.0, b: 31.0 / 255.0)
    static let lightPageRGB = (r: 1.0, g: 1.0, b: 1.0)
    static let pageTitleSize: CGFloat = 34
    static let sectionTitleSize: CGFloat = 22
    static let sidebarWidth: CGFloat = 250
    static let cardCorner: CGFloat = 8
}
```

In `BrandColors`, change magenta/cyan/green dark+light both to `keyColorRGB`, and dark `background` to `darkPageRGB`. Keep `textPrimary` / `textSecondary` as they are (already ~92% / 65%).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --no-parallel --filter ChromeLayoutTests`

Expected: PASS, including the two new tests and existing dock metrics.

- [ ] **Step 5: Patch spec dark background to `#1F1F1F` and commit**

```bash
git add Muses/Sources/Muses/App/AppleMusicTokens.swift \
        Muses/Sources/Muses/App/RootView.swift \
        Muses/Tests/MusesTests/ChromeLayoutTests.swift \
        docs/superpowers/specs/2026-08-20-muses-apple-music-web-visual.md
git commit -m "feat: lock Apple Music Web key color and page tokens"
```

---

### Task 2: Persistent Library sidebar and accent selection

**Files:**
- Modify: `Muses/Sources/Muses/App/AppleMusicTokens.swift` (add `LibraryChromePolicy`)
- Modify: `Muses/Sources/Muses/App/RootView.swift` (`showsLibrarySidebar`, sidebar `.frame(width:)`)
- Modify: `Muses/Sources/Muses/Features/SidebarView.swift` (width, selected glyph)
- Modify: `Muses/Sources/Muses/Features/Shared/ChromeGlyph.swift` (selected uses magenta, glow radius 0)
- Modify: `Muses/Tests/MusesTests/ChromeLayoutTests.swift`

**Interfaces:**
- Consumes: `AppleMusicTokens.sidebarWidth`, `SidebarSection.isLibrary`
- Produces: `LibraryChromePolicy.showsSidebar(section:collapsed:) -> Bool` = `!collapsed`. `ChromeGlyphStyle.selectedGlowRadius == 0`, `selectedUsesAccent == true`.

- [ ] **Step 1: Write failing chrome-policy tests**

```swift
@Test("library sidebar stays visible on Home and New")
func sidebarAlwaysVisibleUnlessCollapsed() {
    #expect(LibraryChromePolicy.showsSidebar(section: .home, collapsed: false))
    #expect(LibraryChromePolicy.showsSidebar(section: .new, collapsed: false))
    #expect(LibraryChromePolicy.showsSidebar(section: .songs, collapsed: false))
    #expect(!LibraryChromePolicy.showsSidebar(section: .home, collapsed: true))
}

@Test("selected chrome glyph uses accent and no glow")
func selectedGlyphIsAccentWithoutGlow() {
    #expect(ChromeGlyphStyle.selectedGlowRadius == 0)
    #expect(ChromeGlyphStyle.selectedUsesAccent)
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --no-parallel --filter ChromeLayoutTests.sidebarAlwaysVisibleUnlessCollapsed`

Expected: FAIL, `LibraryChromePolicy` not found.

- [ ] **Step 3: Implement policy, always-on sidebar, glyph accent**

```swift
enum LibraryChromePolicy {
    static func showsSidebar(section: SidebarSection, collapsed: Bool) -> Bool {
        !collapsed
    }
}

enum ChromeGlyphStyle {
    static let selectedGlowRadius: CGFloat = 0
    static let selectedUsesAccent = true
}
```

`RootView.showsLibrarySidebar` becomes `LibraryChromePolicy.showsSidebar(section: section, collapsed: sidebarCollapsed)`. Sidebar `.frame(width: AppleMusicTokens.sidebarWidth)`.

`ChromeGlyph`: selected foreground `BrandColors.magenta`, idle `BrandColors.textPrimary` at 0.7 opacity, no `.glow`.

`AppTopBar` tabs: drop `.glow(...)`. Selected = semibold primary, unselected = 0.7 opacity.

`SidebarView` comment and width: always shown by parent; keep items unchanged.

- [ ] **Step 4: Run tests**

Run: `swift test --no-parallel --filter ChromeLayoutTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muses/Sources/Muses/App/AppleMusicTokens.swift \
        Muses/Sources/Muses/App/RootView.swift \
        Muses/Sources/Muses/Features/SidebarView.swift \
        Muses/Sources/Muses/Features/Shared/ChromeGlyph.swift \
        Muses/Sources/Muses/Features/AppTopBar.swift \
        Muses/Tests/MusesTests/ChromeLayoutTests.swift
git commit -m "feat: keep Library pane on Home and New, accent selected rows"
```

---

### Task 3: Top-bar search field and content-area search

**Files:**
- Modify: `Muses/Sources/Muses/App/AppleMusicTokens.swift` (`SearchChromePolicy`)
- Modify: `Muses/Sources/Muses/Features/AppTopBar.swift`
- Modify: `Muses/Sources/Muses/App/RootView.swift` (`showSearch` overlay → content)
- Modify: `Muses/Sources/Muses/Features/Search/GlobalSearchView.swift`
- Modify: `Muses/Tests/MusesTests/ChromeLayoutTests.swift`
- Modify: `Muses/Tests/MusesTests/GlobalSearchTests.swift` only if a new helper needs coverage

**Interfaces:**
- Consumes: `GlobalSearchService.query`, `.musesFocusSearch`
- Produces: `SearchChromePolicy.occupiesContent(query:) -> Bool`. Top bar `TextField` writes `search.query`. Root shows `GlobalSearchView` in `detailStack` when occupiesContent. Esc / empty query restores previous page. Overlay scrim search is removed.

- [ ] **Step 1: Write failing search-policy test**

```swift
@Test("search occupies content after first non-empty character")
func searchOccupiesContent() {
    #expect(!SearchChromePolicy.occupiesContent(query: ""))
    #expect(!SearchChromePolicy.occupiesContent(query: "   "))
    #expect(SearchChromePolicy.occupiesContent(query: "a"))
    #expect(SearchChromePolicy.topResult(from: ["Alpha", "Alpine", "Beta"], query: "alp") == "Alpha")
}
```

`topResult` returns the first case-insensitive prefix match, else the first item.

- [ ] **Step 2: Run to verify fail**

Run: `swift test --no-parallel --filter ChromeLayoutTests.searchOccupiesContent`

Expected: FAIL.

- [ ] **Step 3: Implement policy + wiring**

```swift
enum SearchChromePolicy {
    static func occupiesContent(query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func topResult(from titles: [String], query: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        if let prefix = titles.first(where: { $0.localizedCaseInsensitiveHasPrefix(q) }) {
            return prefix
        }
        return titles.first
    }
}
```

`AppTopBar`: inject `@Environment(GlobalSearchService.self)`, replace the search `Button` with a capsule `HStack` containing a magnifying glass and `TextField` bound to `search.query`, `.textFieldStyle(.plain)`, width 196, height 28. `@FocusState private var searchFocused`. On `.musesFocusSearch`, set `searchFocused = true` (do not toggle an overlay).

`RootView`:
- Remove the `showSearch` overlay.
- In `detailStack`, if `SearchChromePolicy.occupiesContent(query: search.query)` and `!showSettings` and `!showNowPlaying`, show `GlobalSearchView` as the content (no scrim).
- Esc: if search occupies content, clear `search.query` and do not close the window.

`GlobalSearchView`:
- Drop scrim, fixed 560×520 panel, and its own TextField (query lives in the top bar).
- Full-size content: page title `tr("Search", "搜索")` at `AppleMusicTokens.pageTitleSize`, then Top Result card (first YouTube hit if `includeYouTube && !youtubeResults.isEmpty`, else first track title via `SearchChromePolicy.topResult`), then Songs (`trackResults` + `youtubeResults`) and Playlists if any.
- Current playing row title uses `BrandColors.magenta`.
- Keep play / context menu / empty/error copy.

- [ ] **Step 4: Run tests**

Run: `swift test --no-parallel --filter ChromeLayoutTests` and `swift test --no-parallel --filter GlobalSearchTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muses/Sources/Muses/App/AppleMusicTokens.swift \
        Muses/Sources/Muses/Features/AppTopBar.swift \
        Muses/Sources/Muses/App/RootView.swift \
        Muses/Sources/Muses/Features/Search/GlobalSearchView.swift \
        Muses/Tests/MusesTests/ChromeLayoutTests.swift
git commit -m "feat: Apple Music content-area search from the top-bar field"
```

---

### Task 4: Dock transport, lyrics policy, card Play

**Files:**
- Modify: `Muses/Sources/Muses/App/AppleMusicTokens.swift` (`DockLyricsPolicy`)
- Modify: `Muses/Sources/Muses/Features/PlayerBar.swift`
- Modify: `Muses/Sources/Muses/App/RootView.swift` (`onLyricsTap`)
- Modify: `Muses/Sources/Muses/Features/Shared/HoverPlayButton.swift`
- Modify: `Muses/Sources/Muses/Features/NowPlaying/NowPlayingView.swift` (glow → shadow)
- Modify: `Muses/Tests/MusesTests/ChromeLayoutTests.swift`

**Interfaces:**
- Consumes: `showNowPlaying`, `nowPlayingShowLyrics`
- Produces: `DockLyricsPolicy.action(nowPlayingOpen:) -> DockLyricsPolicy.Action` where `.openNowPlaying` / `.toggleLyricsFocus`. Scrubber `.tint(BrandColors.magenta)`. Hover Play circle fill = magenta, white glyph, no glass.

- [ ] **Step 1: Write failing lyrics-policy test**

```swift
@Test("dock lyrics opens Now Playing or toggles lyrics focus")
func dockLyricsPolicy() {
    #expect(DockLyricsPolicy.action(nowPlayingOpen: false) == .openNowPlaying)
    #expect(DockLyricsPolicy.action(nowPlayingOpen: true) == .toggleLyricsFocus)
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --no-parallel --filter ChromeLayoutTests.dockLyricsPolicy`

Expected: FAIL.

- [ ] **Step 3: Implement**

```swift
enum DockLyricsPolicy {
    enum Action: Equatable { case openNowPlaying, toggleLyricsFocus }
    static func action(nowPlayingOpen: Bool) -> Action {
        nowPlayingOpen ? .toggleLyricsFocus : .openNowPlaying
    }
}
```

`RootView.onLyricsTap`:
```
showQueue = false
switch DockLyricsPolicy.action(nowPlayingOpen: showNowPlaying) {
case .openNowPlaying:
    nowPlayingShowLyrics = true
    showNowPlaying = true
case .toggleLyricsFocus:
    nowPlayingShowLyrics.toggle()
}
showLyricsDrawer = false
```

Stop presenting `LyricsDrawerView` from the dock. Queue drawer stays.

`PlayerBar` scrubber and volume slider `.tint(BrandColors.magenta)`. Dock play `ChromeGlyph` stays primary (not selected/magenta). Playing artwork: remove `.glow`, use `.shadow(color: .black.opacity(0.35), radius: isPlaying ? 8 : 0)`.

`HoverPlayButton`: `BrandColors.magenta` circle, white `play.fill`, no `musesGlass`. Reduce Transparency keeps the same fill (already opaque).

`NowPlayingView.centerContent`: replace `.glow` with the same soft shadow.

- [ ] **Step 4: Run tests**

Run: `swift test --no-parallel --filter ChromeLayoutTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muses/Sources/Muses/App/AppleMusicTokens.swift \
        Muses/Sources/Muses/App/RootView.swift \
        Muses/Sources/Muses/Features/PlayerBar.swift \
        Muses/Sources/Muses/Features/Shared/HoverPlayButton.swift \
        Muses/Sources/Muses/Features/NowPlaying/NowPlayingView.swift \
        Muses/Tests/MusesTests/ChromeLayoutTests.swift
git commit -m "feat: pink scrubber and card Play, dock lyrics opens Now Playing"
```

---

### Task 5: Home Listen Now layout

**Files:**
- Modify: `Muses/Sources/Muses/App/AppleMusicTokens.swift` (`TopPicksResolver`)
- Modify: `Muses/Sources/Muses/Features/HomeView.swift`
- Modify: `Muses/Sources/Muses/Features/Shared/HeroObject.swift` (optional editorial card variant, only if Home needs 2–3 large cards without a new file explosion — prefer a small `TopPickCard` in HomeView or Shared)
- Modify: `Muses/Tests/MusesTests/ChromeLayoutTests.swift`
- Test: existing `PhaseD3HomeDiscoveryTests.swift` must still pass

**Interfaces:**
- Consumes: `HomeSection.items`, `recentlyPlayed`, optional hero `DiscoveryItem`
- Produces: `TopPicksResolver.picks(hero:mixed:recent:max:) -> [DiscoveryItem]` with `max == 3`, first-seen `id` wins, mixed before recent. Home page title 34pt heavy `tr("Home", "首页")`. Top Picks row of 2–3 cards. Then Recently Played rail. Then remaining discovery rails. Your Playlists rail if imports exist and are not already a discovery section.

- [ ] **Step 1: Write failing Top Picks tests**

```swift
@Test("Top Picks prefers hero then mixed then recent, max three unique")
func topPicksResolver() {
    func yt(_ id: String) -> DiscoveryItem {
        .youTube(YouTubeDiscoveryCard(id: id, title: id))
    }
    let picks = TopPicksResolver.picks(
        hero: yt("h"),
        mixed: [yt("h"), yt("m1"), yt("m2")],
        recent: [yt("m1"), yt("r1")],
        max: 3
    )
    #expect(picks.map(\.id) == ["yt:h", "yt:m1", "yt:m2"])
}

@Test("Top Picks does not fabricate cards")
func topPicksSparse() {
    let picks = TopPicksResolver.picks(hero: nil, mixed: [], recent: [
        .youTube(YouTubeDiscoveryCard(id: "only", title: "only"))
    ], max: 3)
    #expect(picks.count == 1)
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --no-parallel --filter ChromeLayoutTests.topPicksResolver`

Expected: FAIL.

- [ ] **Step 3: Implement resolver and Home layout**

```swift
enum TopPicksResolver {
    static func picks(hero: DiscoveryItem?,
                      mixed: [DiscoveryItem],
                      recent: [DiscoveryItem],
                      max: Int = 3) -> [DiscoveryItem] {
        var out: [DiscoveryItem] = []
        var seen = Set<String>()
        func add(_ item: DiscoveryItem) {
            guard out.count < max, seen.insert(item.id).inserted else { return }
            out.append(item)
        }
        if let hero { add(hero) }
        mixed.forEach(add)
        recent.forEach(add)
        return out
    }
}
```

Home:
- Title font `.system(size: AppleMusicTokens.pageTitleSize, weight: .heavy)`.
- Build mixed = first `HomeSection` whose `kind` is `.mixed` or `.youTubeCarousel`, else `sections.first?.items ?? []`.
- Hero item: if `heroAlbum` exists, `DiscoveryItem.album(AlbumRef(album: heroAlbum))`.
- Recent items: map `recentlyPlayed` to `.track`.
- Render Top Picks as an `HStack` of up to 3 square `AlbumObjectView` / YouTube cards at ~ `MusicObjectMetrics.albumHero`, overlay title, `HoverPlayButton`. Do not use 16:9 slots.
- Keep Recently Played rail, then skip the section already consumed as mixed for Top Picks, render the rest as rails with section title `.system(size: AppleMusicTokens.sectionTitleSize, weight: .semibold)`.
- Your Playlists: if `ytImports` is non-empty and no discovery section titled like playlists, show a rail.
- Focus still suppresses discovery. `loadMore` unchanged.
- Drop the artwork-derived full-page gradient if it fights AM’s flat `#1F1F1F` page (use `BrowseBackground` / `BrandColors.background` only).

- [ ] **Step 4: Run tests**

Run: `swift test --no-parallel --filter ChromeLayoutTests` and `swift test --no-parallel --filter PhaseD3HomeDiscoveryTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muses/Sources/Muses/App/AppleMusicTokens.swift \
        Muses/Sources/Muses/Features/HomeView.swift \
        Muses/Tests/MusesTests/ChromeLayoutTests.swift
git commit -m "feat: restyle Home as Apple Music Listen Now with Top Picks"
```

---

### Task 6: New page title and featured slot

**Files:**
- Modify: `Muses/Sources/Muses/Features/NewView.swift`
- Modify: `Muses/Tests/MusesTests/ChromeLayoutTests.swift` (page title size already covered)

**Interfaces:**
- Consumes: existing `RecommendationService` / `SituationalRecommendationService` data
- Produces: New title 34pt heavy. First available album/section item as one large featured card (square crop + Play). Remaining sections as 22pt rails. No new data source.

- [ ] **Step 1: Write a featured-slot helper test**

```swift
@Test("New featured slot is the first available item")
func newFeaturedSlot() {
    let items = [
        DiscoveryItem.youTube(YouTubeDiscoveryCard(id: "a", title: "A")),
        DiscoveryItem.youTube(YouTubeDiscoveryCard(id: "b", title: "B"))
    ]
    #expect(NewFeaturedResolver.featured(from: items)?.id == "yt:a")
    #expect(NewFeaturedResolver.featured(from: []) == nil)
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --no-parallel --filter ChromeLayoutTests.newFeaturedSlot`

Expected: FAIL.

- [ ] **Step 3: Implement**

```swift
enum NewFeaturedResolver {
    static func featured(from items: [DiscoveryItem]) -> DiscoveryItem? { items.first }
}
```

`NewView`: page title `AppleMusicTokens.pageTitleSize` heavy. If situational: first section’s first item as featured square card, remaining items/sections as rails. If legacy: first album of the first non-empty rec list as featured, rest as rails. Keep skeletons and Focus behavior.

- [ ] **Step 4: Run tests**

Run: `swift test --no-parallel --filter ChromeLayoutTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muses/Sources/Muses/App/AppleMusicTokens.swift \
        Muses/Sources/Muses/Features/NewView.swift \
        Muses/Tests/MusesTests/ChromeLayoutTests.swift
git commit -m "feat: restyle New with Apple Music featured slot and 34pt title"
```

---

### Task 7: Settings as Account content page

**Files:**
- Modify: `Muses/Sources/Muses/Features/Settings/SettingsSheet.swift`
- Modify: `Muses/Sources/Muses/App/RootView.swift`
- Modify: `Muses/Tests/MusesTests/ChromeLayoutTests.swift`

**Interfaces:**
- Consumes: `SettingsCategory`, `initialSettingsCategory`, `YouTubeAccountService`
- Produces: `SettingsChromePolicy.showsAccount(isPresented:)` → Bool. Avatar still sets `showSettings = true`. Root shows Account in `detailStack` (sidebar + dock remain). No 680×520 scrim panel. Esc / Back clears `showSettings`. Deep link `initialSettingsCategory` opens that detail.

- [ ] **Step 1: Write failing settings-policy test**

```swift
@Test("Settings occupies content while presented")
func settingsOccupiesContent() {
    #expect(SettingsChromePolicy.showsAccount(isPresented: true))
    #expect(!SettingsChromePolicy.showsAccount(isPresented: false))
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --no-parallel --filter ChromeLayoutTests.settingsOccupiesContent`

Expected: FAIL.

- [ ] **Step 3: Implement Account page**

```swift
enum SettingsChromePolicy {
    static func showsAccount(isPresented: Bool) -> Bool { isPresented }
}
```

Rename/split `SettingsSheet` into `SettingsAccountView` used as content:
- Title `tr("Settings", "设置")` at 34pt.
- Circular avatar, YouTube name or signed-out prompt, Connect / Sign out (reuse existing account actions).
- Grouped list of `SettingsCategory.allCases` with icons.
- Selecting a category shows the existing Form body (`GPUSettingsView`, playback, quality, YouTube + yt-dlp wizard, etc.) in the same slot with a Back control.
- `initialCategory` selects that detail on appear.

`RootView`: if `showSettings`, `detailStack` shows `SettingsAccountView`. Remove overlay `SettingsSheet`. `onLyricsTap` / search do not need to close Settings unless Esc. Esc: Settings first, then search query, then Now Playing.

Priority of content slot (highest wins): Settings, Search (non-empty query), Now Playing overlay stays as today (Now Playing is an overlay above detail, not a detailStack replacement). Spec: NP fills content slot — keep current NP overlay so artwork morph still works. Settings and Search replace `detailStack` under that overlay.

- [ ] **Step 4: Run tests**

Run: `swift test --no-parallel --filter ChromeLayoutTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muses/Sources/Muses/App/AppleMusicTokens.swift \
        Muses/Sources/Muses/App/RootView.swift \
        Muses/Sources/Muses/Features/Settings/SettingsSheet.swift \
        Muses/Tests/MusesTests/ChromeLayoutTests.swift
git commit -m "feat: present Settings as an Apple Music account content page"
```

---

### Task 8: List language, queue current row, verification

**Files:**
- Modify: `Muses/Sources/Muses/Features/Queue/QueueDrawerView.swift` (already uses magenta — confirm)
- Modify: playlist / songs rows only if current title is not magenta
- Modify: `Muses/Tests/MusesTests/ChromeLayoutTests.swift` (final shell assertions)
- Do not change playback tests unless they assert colors

**Interfaces:**
- Consumes: `BrandColors.magenta` now pink
- Produces: current track titles already on magenta pick up pink. Add a regression test that dock height, sidebar width, key color, sidebar-on-home, search policy, and lyrics policy still hold together.

- [ ] **Step 1: Add a single contract test that locks the shell**

```swift
@Test("Apple Music shell contract")
func appleMusicShellContract() {
    #expect(PlayerDockMetrics.height == 72)
    #expect(AppleMusicTokens.sidebarWidth == 250)
    #expect(LibraryChromePolicy.showsSidebar(section: .home, collapsed: false))
    #expect(SearchChromePolicy.occupiesContent(query: "q"))
    #expect(DockLyricsPolicy.action(nowPlayingOpen: false) == .openNowPlaying)
    #expect(ChromeGlyphStyle.selectedGlowRadius == 0)
    #expect(AppleMusicTokens.keyColorHex == "FA586A")
}
```

- [ ] **Step 2: Run to verify (should pass if earlier tasks landed)**

Run: `swift test --no-parallel --filter ChromeLayoutTests.appleMusicShellContract`

If it fails, fix the missing policy rather than weakening the test.

- [ ] **Step 3: Sweep remaining white-glow call sites on chrome**

`rg 'glow\\(' Muses/Sources/Muses/Features` — remove glow from PlayerBar identity, AppTopBar, ChromeGlyph, Now Playing cover. Playing cover shadow only. Do not touch Metal spectrum.

Queue current row already uses `BrandColors.magenta`. Leave playback/queue logic alone.

- [ ] **Step 4: Full test run**

Run: `make test`

Expected: PASS. If a test asserted magenta == white/black, update it to key color.

- [ ] **Step 5: Commit**

```bash
git add Muses/Tests/MusesTests/ChromeLayoutTests.swift \
        Muses/Sources/Muses/Features/PlayerBar.swift \
        Muses/Sources/Muses/Features/AppTopBar.swift \
        Muses/Sources/Muses/Features/NowPlaying/NowPlayingView.swift
git commit -m "test: lock Apple Music shell contract and drop remaining chrome glow"
```

---

## Self-review

**Spec coverage**
- §3 tokens → Task 1
- §3.5 no glow / cover shadow → Tasks 2, 4, 8
- §4 shell, always-on sidebar, dock AirPlay=YouTube → Tasks 2, 4
- §4.1 top bar search field → Task 3
- §5 Home Listen Now → Task 5
- §5.2 New → Task 6
- §6 Now Playing lyrics focus → Task 4 (NP already has title under cover)
- §7 Search content page → Task 3
- §8 list language → Task 1 (magenta) + Task 8
- §9 Settings Account page → Task 7
- §10 YouTubeMark red → no recolor
- §13 engines untouched
- §14 verification tests → ChromeLayoutTests across tasks; `make test` in Task 8

**Placeholder scan:** none. Types named in later tasks are defined in Task 1–4 (`AppleMusicTokens`, policies).

**Type consistency:** `LibraryChromePolicy.showsSidebar(section:collapsed:)`, `SearchChromePolicy.occupiesContent(query:)`, `DockLyricsPolicy.Action`, `TopPicksResolver.picks(hero:mixed:recent:max:)`, `NewFeaturedResolver.featured(from:)`, `SettingsChromePolicy.showsAccount(isPresented:)`.
