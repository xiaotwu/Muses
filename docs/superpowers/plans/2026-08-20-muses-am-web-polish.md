# Apple Music Web polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Polish Muses against live `music.apple.com` measurements: sticky bottom capsule, no page tints, full-row sidebar hits, floating glass Settings, Apple-style Muses wordmark, AM spacing + 540×309 heroes, and lazy playlist lists.

**Architecture:** Lock live CSS numbers in `AppleMusicTokens`. Player sits in the content-column `VStack` (not a window `ZStack` overlay). Settings returns to a centered glass overlay. Playlist screens drop the `minHeight: count * 56` eager layout and render `TrackSnapshot` rows in a lazy stack.

**Tech Stack:** Swift 6 / SwiftUI / Swift Testing. `swift test --no-parallel --filter ChromeLayoutTests`. No new dependencies. Wordmark is SwiftUI (not a generated PNG with text).

**Spec:** `docs/superpowers/specs/2026-08-20-muses-apple-music-web-visual.md` plus live measurements 2026-08-20 (1440×900):

```
nav: margin 8px 0 0 8px, width 244, radius 20, bg rgba(38,38,40,0.6), blur(16px) saturate(2.2)
nav item: height 34, font 14
player-bar: position sticky, bottom 0, padding 0 20px, margin-bottom 20px, height 54–56
chrome-player: 668×56, radius 1000px
editorial: grid 540px, image 540×309, gap 24×20, shelf pad 0 40px
h1: 34px / 700
```

## Global Constraints

- Do not edit `PlaybackService`, engines, `QueueService` internals, OAuth, or SwiftData schema.
- User-visible strings: `tr("English", "中文")`.
- YouTubeMark stays red. Accent `#FA586A`.
- Playlist lists must stay lazy. Never set `minHeight` to `rowCount * rowHeight`.
- Settings is a centered ~520×560 liquid-glass panel; click scrim, Esc, or any sidebar destination closes it.
- Player is in layout flow at the bottom of the content column, 20pt from the window bottom, not `position: absolute` over the window.

---

## File Structure

```
Muses/Sources/Muses/App/AppleMusicTokens.swift
Muses/Sources/Muses/App/RootView.swift
Muses/Sources/Muses/Features/PlayerBar.swift
Muses/Sources/Muses/Features/SidebarView.swift
Muses/Sources/Muses/Features/Playlist/PlaylistSidebarRow.swift
Muses/Sources/Muses/Features/Settings/SettingsSheet.swift
Muses/Sources/Muses/Features/Shared/MusesWordmark.swift          (new)
Muses/Sources/Muses/Features/Shared/EditorialCard.swift
Muses/Sources/Muses/Features/Shared/BrowseBackground.swift
Muses/Sources/Muses/Features/HomeView.swift
Muses/Sources/Muses/Features/YouTube/YouTubeAlbumDetailView.swift
Muses/Sources/Muses/Features/Playlist/PlaylistDetailView.swift
Muses/Sources/Muses/Features/AlbumDetailView.swift
Muses/Tests/MusesTests/ChromeLayoutTests.swift
```

---

### Task 1: Lock live spacing + layout policies

**Files:**
- Modify: `Muses/Sources/Muses/App/AppleMusicTokens.swift`
- Modify: `Muses/Tests/MusesTests/ChromeLayoutTests.swift`

**Interfaces:**
- Produces: `AppleMusicTokens.sidebarInsetTopLeading == 8`, `sidebarWidth == 244`, `playerBottomMargin == 20`, `editorialWidth == 540`, `editorialHeight == 309`, `contentPaddingX == 40`, `navItemHeight == 34`. `PlayerLayoutPolicy.isWindowOverlay == false`. `PlaylistListPolicy.minListHeight(rowCount:rowHeight:) -> CGFloat?` returns `nil`. `SidebarRowHitPolicy.usesFullRowHitTarget == true`. `SettingsChromePolicy.presentsAsFloatingGlass == true`.

- [ ] **Step 1: Write failing tests**

```swift
@Test("live AM Web spacing tokens")
func liveSpacingTokens() {
    #expect(AppleMusicTokens.sidebarInset == 8)
    #expect(AppleMusicTokens.sidebarWidth == 244)
    #expect(AppleMusicTokens.playerBottomMargin == 20)
    #expect(AppleMusicTokens.editorialWidth == 540)
    #expect(AppleMusicTokens.editorialHeight == 309)
    #expect(AppleMusicTokens.contentPaddingX == 40)
    #expect(AppleMusicTokens.navItemHeight == 34)
    #expect(AppleMusicTokens.capsuleWidth == 668)
}

@Test("player is sticky in the content column, not a window overlay")
func playerNotWindowOverlay() {
    #expect(!PlayerLayoutPolicy.isWindowOverlay)
}

@Test("playlist list never forces height of every row")
func playlistListIsLazy() {
    #expect(PlaylistListPolicy.minListHeight(rowCount: 500, rowHeight: 56) == nil)
}

@Test("sidebar rows use the full row as the hit target")
func sidebarFullRowHit() {
    #expect(SidebarRowHitPolicy.usesFullRowHitTarget)
}

@Test("Settings is a floating glass panel")
func settingsFloatingGlass() {
    #expect(SettingsChromePolicy.presentsAsFloatingGlass)
}
```

- [ ] **Step 2: Run to fail**

Run: `swift test --no-parallel --filter ChromeLayoutTests.liveSpacingTokens`

Expected: FAIL on missing tokens / `sidebarWidth` still 240.

- [ ] **Step 3: Implement tokens and policies**

```swift
enum PlayerLayoutPolicy {
    static let isWindowOverlay = false
}

enum PlaylistListPolicy {
    static func minListHeight(rowCount: Int, rowHeight: CGFloat) -> CGFloat? { nil }
}

enum SidebarRowHitPolicy {
    static let usesFullRowHitTarget = true
}
```

Set `SettingsChromePolicy.presentsAsFloatingGlass = true` (add the property). Update token numbers to the live values above.

- [ ] **Step 4: Run tests**

Run: `swift test --no-parallel --filter ChromeLayoutTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muses/Sources/Muses/App/AppleMusicTokens.swift Muses/Tests/MusesTests/ChromeLayoutTests.swift
git commit -m "test: lock live Apple Music Web spacing and layout policies"
```

---

### Task 2: Player in content-column flow + strip page tints

**Files:**
- Modify: `Muses/Sources/Muses/App/RootView.swift` (`splitView`)
- Modify: `Muses/Sources/Muses/Features/YouTube/YouTubeAlbumDetailView.swift` (remove gradient + `minHeight`)
- Modify: `Muses/Sources/Muses/Features/AlbumDetailView.swift` (remove artwork gradient)
- Modify: `Muses/Sources/Muses/Features/Shared/BrowseBackground.swift` (already flat; keep)

**Interfaces:**
- Consumes: `PlayerLayoutPolicy.isWindowOverlay == false`, `playerBottomMargin`
- Produces: `HStack { sidebar; VStack { detail; PlayerBar.padding(.bottom, 20) } }`. Now Playing overlay bottom inset uses `capsuleHeight + 20`. No `LinearGradient` page fill on album / YouTube import detail.

- [ ] **Step 1: Confirm existing tests still require `!isWindowOverlay`** (already in Task 1).

- [ ] **Step 2: Implement RootView**

Replace the `ZStack(alignment: .bottom)` player overlay with:

```swift
HStack(spacing: 0) {
    sidebar.padding(.leading, 8).padding(.top, 8)
    VStack(spacing: 0) {
        detailStack.frame(maxWidth: .infinity, maxHeight: .infinity)
        if !showYouTubeVideo {
            PlayerBar(...)
                .padding(.bottom, AppleMusicTokens.playerBottomMargin)
        }
    }
}
```

Set `chromeTop = 0`, `chromeBottom = capsuleHeight + playerBottomMargin`.

- [ ] **Step 3: Remove tints**

`YouTubeAlbumDetailView`: delete `LinearGradient` + `ArtworkReadableScrim`; use `BrandColors.background`. `AlbumDetailView`: same. Keep `BrowseBackground` as solid `BrandColors.background`.

- [ ] **Step 4: Run** `swift test --no-parallel --filter ChromeLayoutTests` — PASS.

- [ ] **Step 5: Commit** `fix: pin player to content bottom and drop page gradients`

---

### Task 3: Full-row playlist hit + Muses wordmark + glass Settings

**Files:**
- Modify: `Muses/Sources/Muses/Features/Playlist/PlaylistSidebarRow.swift`
- Create: `Muses/Sources/Muses/Features/Shared/MusesWordmark.swift`
- Modify: `Muses/Sources/Muses/Features/SidebarView.swift`
- Modify: `Muses/Sources/Muses/Features/Settings/SettingsSheet.swift`
- Modify: `Muses/Sources/Muses/App/RootView.swift` (overlay Settings again; sidebar taps set `showSettings = false`)

**Interfaces:**
- Consumes: `SidebarRowHitPolicy`, `SettingsChromePolicy.presentsAsFloatingGlass`
- Produces: row `.contentShape(Rectangle())` + `maxWidth: .infinity` alignment leading. `MusesWordmark` = 20×20 rounded mark + “Muses” text (Apple Music logo layout). Settings overlay 520×560 `musesGlass`, scrim tap / Esc / sidebar nav closes.

- [ ] **Step 1: Tests already cover policies.** Add:

```swift
@Test("Muses wordmark is icon plus text")
func musesWordmarkLayout() {
    #expect(MusesWordmarkMetrics.icon == 20)
    #expect(MusesWordmarkMetrics.showsText)
}
```

- [ ] **Step 2: Run to fail** if metrics missing.

- [ ] **Step 3: Implement**

`PlaylistSidebarRow` label: `HStack { ... Spacer } .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())`. Button `.buttonStyle(.plain)`.

`MusesWordmark`: HStack spacing 6; rounded rect 20×20 (continuous, ~5pt radius) filled with `textPrimary`, white/black `music.note` (or bundled `logo.png` if present); `Text("Muses")` system 15 semibold. Use in `SidebarView` instead of `Text("Muses").font(BrandFont.muses)`.

Settings: restore overlay in `RootView` (not `detailStack`). Panel `frame(width: 520, height: 560)`, `musesGlass(cornerRadius: 18)`. Scrim tap → close. `SidebarView.navRow` / playlist tap / Search/Home/New → `showSettings = false`. Esc still closes.

- [ ] **Step 4: Run ChromeLayoutTests** — PASS.

- [ ] **Step 5: Commit** `fix: full-row sidebar hits, Muses wordmark, glass Settings overlay`

---

### Task 4: 540×309 heroes and AM spacing

**Files:**
- Modify: `Muses/Sources/Muses/Features/Shared/EditorialCard.swift`
- Modify: `Muses/Sources/Muses/Features/HomeView.swift`
- Modify: `Muses/Sources/Muses/Features/NewView.swift`
- Modify: `Muses/Sources/Muses/Features/SidebarView.swift` (nav item height 34)

**Interfaces:**
- Consumes: `editorialWidth 540`, `editorialHeight 309`, `contentPaddingX 40`
- Produces: editorial cards 540×309, Home/New content padding 40, first shelf is the hero row (no extra “精选” heading), nav rows 34pt tall.

- [ ] **Step 1: Tests already assert 540×309.**

- [ ] **Step 2: EditorialCard default width 540, image height 309.** Home `listenNowTopPicks` uses those defaults, horizontal padding `contentPaddingX`. Page title padding 40. Sidebar `navRow` vertical padding so total height is 34.

- [ ] **Step 3: Run ChromeLayoutTests** — PASS.

- [ ] **Step 4: Commit** `fix: match Apple Music editorial 540x309 and 40pt content inset`

---

### Task 5: Lazy playlist lists

**Files:**
- Modify: `Muses/Sources/Muses/Features/YouTube/YouTubeAlbumDetailView.swift`
- Modify: `Muses/Sources/Muses/Features/Playlist/PlaylistDetailView.swift`
- Modify: `Muses/Tests/MusesTests/ChromeLayoutTests.swift` (already has `minListHeight == nil`)

**Interfaces:**
- Consumes: `PlaylistListPolicy.minListHeight(...) == nil`
- Produces: no `frame(minHeight: count * 56)`. Rows use `TrackSnapshot` collected once (`onAppear` / cached state), `List`/`LazyVStack` without forcing full height. `allSnaps` must not be rebuilt as a computed property that maps every SwiftData `track` during `body`.

- [ ] **Step 1: Test already written.**

- [ ] **Step 2: YouTubeAlbumDetailView**

Delete `.frame(minHeight: CGFloat(max(items.count, 1)) * 56)`.

Replace `var allSnaps` computed relationship walk in `body` with:

```swift
@State private var snaps: [TrackSnapshot] = []

private func reloadSnaps() {
    snaps = (youTubeImport.items ?? [])
        .sorted { $0.order < $1.order }
        .compactMap { item in item.track.map { TrackSnapshot(from: $0) } }
}
```

Call `reloadSnaps()` in `onAppear`. `trackList` `ForEach(snaps)` with `SongObjectView` using snapshot fields only. Do not read `item.track` per row in `body`.

`PlaylistDetailView`: map to snapshots on appear; keep `List` lazy; do not set minHeight from count.

- [ ] **Step 3: Run** `swift test --no-parallel --filter ChromeLayoutTests` and `swift test --no-parallel --filter Playlist` if a playlist suite exists.

- [ ] **Step 4: Commit** `perf: lazy playlist rows without forcing full list height`

---

## Self-review

- §1 player relative bottom → Task 2 (`sticky`/VStack, margin 20)
- §2 remove page backgrounds → Task 2
- §3 full row click → Task 3
- §4 glass Settings → Task 3
- §5 Muses icon+text → Task 3 (`MusesWordmark`, code not image-gen text)
- §6 spacing + heroes 540×309 → Task 1 + 4 (measured live)
- §7 playlist jank → Task 5 (`minHeight` removal is the root cause)
