# Muses Artwork-World Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Muses treat albums, artists, and songs as physical objects with correct collection-context play, desktop hover/selection, and PlayerBar ↔ Now Playing cover continuity — without cloning Apple Music or rewriting engines.

**Architecture:** Views keep calling `PlaybackService.playTrack(_:context:from:)` with `TrackSnapshot` arrays. `ArtworkSource` becomes an identity (file/URL/placeholder); `ArtworkView` + `ImageLoader` own decode. Four Shared primitives (`AlbumObjectView`, `ArtistObjectView`, `SongObjectView`, `HeroObjectView`) replace ad-hoc cards. One `@Namespace` on `RootView` drives a three-layer Now Playing overlay (environment / chrome / live-cover host).

**Tech Stack:** Swift 6 / SwiftUI / Swift Testing / macOS 14+ Apple Silicon. No new dependencies. Tests: `swift test --no-parallel` or `make test`.

**Spec:** `docs/superpowers/specs/2026-08-18-muses-artwork-world-overhaul-design.md`

## Global Constraints

- Platform: **macOS 14+**, Apple Silicon only. Bundle id `com.muses.app`.
- Bilingual user copy via `tr("English", "中文")`. Search is **⌘F**. Queue is **⌘K**.
- `PlaybackService` is the only playback facade. Do **not** edit `PlaybackService` internals, `LocalAudioEngine`, `YouTubeStreamEngine`, `NowPlayingManager`, vinyl rotation math, spectrum FFT, queue persistence, SwiftData schema, OAuth, or yt-dlp.
- No glass on cards. No neon/glow. `BrandColors.magenta` is dark-white / light-black.
- No SwiftData field additions. `TrackSnapshot` stays as-is.
- No new feature flag. Rollback = revert the PR/commit.
- New Swift files under `Muses/Sources/Muses/` are auto-picked up by `Package.swift` (`path: "Muses/Sources/Muses"`). Do not edit the Xcode project unless a file is missing from the target after `swift test`.
- The worktree may still contain uncommitted Liquid Glass diffs. **Do not fold those into artwork-world commits.** Stash or commit glass separately before starting Task 1.
- Honor Reduce Motion and Reduce Transparency on every new animation.
- User-visible strings: Search shortcut is always ⌘F in copy.

---

## File Structure

```
Agents.md / AGENTS.md                          Task 1 — motion + presentation language (keep identical)

Muses/Sources/Muses/Features/HomeView.swift    Tasks 2–3, 5, 7–8, 10
Muses/Sources/Muses/Features/Playlist/PlaylistDetailView.swift   Tasks 2, 7–8
Muses/Sources/Muses/Features/YouTube/YouTubeImportsView.swift    Task 2 (import row context)
Muses/Sources/Muses/Features/LibraryView.swift Tasks 3, 5, 7–8
Muses/Sources/Muses/App/RootView.swift         Tasks 3, 9
Muses/Sources/Muses/Features/SidebarView.swift Task 3
Muses/Sources/Muses/Features/Search/GlobalSearchView.swift  Tasks 3, 5
Muses/Sources/Muses/Features/Queue/QueueDrawerView.swift    Task 3

Muses/Sources/Muses/Features/NowPlaying/ArtworkSource.swift     Task 4
Muses/Sources/Muses/Infrastructure/ImageLoader.swift            Task 4
Muses/Sources/Muses/Features/NowPlaying/NowPlayingView.swift    Tasks 4, 9
Muses/Sources/Muses/Features/PlayerBar.swift                    Tasks 5, 9
+ remaining body-decode sites listed in Task 5

Muses/Sources/Muses/Features/Shared/MusicObjectMetrics.swift    Task 6
Muses/Sources/Muses/Features/Shared/AlbumObject.swift           Tasks 6–8
Muses/Sources/Muses/Features/Shared/ArtistObject.swift          Tasks 6–8
Muses/Sources/Muses/Features/Shared/SongObject.swift            Tasks 6–8
Muses/Sources/Muses/Features/Shared/HeroObject.swift            Tasks 6–8
Muses/Sources/Muses/Features/Shared/HoverPlayButton.swift       Task 8
Muses/Sources/Muses/Features/Shared/NowPlayingMark.swift        Task 8
Muses/Sources/Muses/Features/Shared/MusesMotion.swift           Task 8
Muses/Sources/Muses/Features/Shared/ArtworkContinuity.swift     Task 9

Muses/Tests/MusesTests/QueueServiceTests.swift                  Task 2
Muses/Tests/MusesTests/PlaybackServiceTests.swift               Task 2
Muses/Tests/MusesTests/ArtworkCacheTests.swift                  Task 4
Muses/Tests/MusesTests/PhaseP3EnrichmentTests.swift             Task 4

artifacts/artwork-world-qa-2026-08-18/                          Task 10
```

Do **not** create `ArtworkWorldHCITests.swift`. Do **not** convert `YouTubeImportCard`. Do **not** wire `LikedView` into the sidebar.

---

### Task 1: Lock artwork-world language in Agents.md

**Files:**
- Modify: `Agents.md`
- Modify: `AGENTS.md` (byte-identical to `Agents.md` after this task)

**Interfaces:**
- Consumes: spec §2 Key Decisions, §5.5.1
- Produces: durable agent rules later tasks must obey

- [ ] **Step 1: Edit Visual Hierarchy**

In both files, under `### Visual Hierarchy`, keep the existing five bullets and append:

```markdown
- Home / New rails may use larger artwork, hover Play, and now-playing identity. They must stay calmer than Now Playing.
- Album, artist, and playlist detail may use environmental color and a playing-row. They are artwork environments, not a second Now Playing.
```

- [ ] **Step 2: Replace the Motion section**

Replace the entire `## Motion` section in both files with:

```markdown
## Motion

Motion should communicate hierarchy, navigation, continuity, playback state, expansion/collapse, or spatial relationships.

A centralized motion/continuity system may coordinate:

- Artwork continuity (PlayerBar ↔ Now Playing matched geometry).
- Glass morphing on **chrome only** (PlayerBar, Search, Queue, compact controls).
- Queue presentation.
- Contextual controls and hover Play.

Rules:

- Prefer continuity between related surfaces over unrelated transitions.
- Hover is 120–180ms ease, a few points of lift, no bounce, no idle motion on browsing surfaces.
- Playback-position, spectrum, and vinyl **may** animate. List rows and chrome **must not** sample those clocks.
- Do not glass-morph browsing cards.
- Do not add animation to high-frequency state without evaluating frame pacing, CPU, energy, and accessibility impact.
- Respect Reduce Motion in every new animation path, including custom Metal/AppKit rendering. Reduce Motion fallback is instant swap or opacity.
```

- [ ] **Step 3: Keep the clone / glass / engine locks**

Confirm these sentences still exist unchanged in both files:

- “A Spotify or Apple Music clone”
- Liquid Glass: custom glass only for meaningful application-specific surfaces
- High-Risk Areas still lists `PlaybackService`, engines, `PlayerBar`, `NowPlayingView`
- “Do not opportunistically refactor these systems during unrelated visual tasks.”

- [ ] **Step 4: Keep the two files identical**

```bash
diff -q Agents.md AGENTS.md
```

Expected: no output (files identical).

- [ ] **Step 5: Commit**

```bash
git add Agents.md AGENTS.md
git commit -m "docs: lock artwork-world motion and presentation language"
```

---

### Task 2: Play-context correctness

**Files:**
- Test: `Muses/Tests/MusesTests/QueueServiceTests.swift`
- Test: `Muses/Tests/MusesTests/PlaybackServiceTests.swift`
- Modify: `Muses/Sources/Muses/Features/HomeView.swift` (~223–226)
- Modify: `Muses/Sources/Muses/Features/Playlist/PlaylistDetailView.swift` (~163–165)
- Modify: `Muses/Sources/Muses/Features/YouTube/YouTubeImportsView.swift` (~295–299)

**Interfaces:**
- Consumes: `QueueService.play(_:context:from:)`, `PlaybackService.playTrack(_:context:from:)`, `QueueSource.recently` / `.playlist` / `.import`
- Produces: Recently Played, playlist in-row Play, and YouTube-import in-row Play pass the **visible list**, not `[snap]`

- [ ] **Step 1: Write the failing QueueService tests**

Append to `QueueServiceTests.swift` (reuse the existing `snap(_:)` helper):

```swift
@Test("recently-played context keeps full list and tapped index")
func recentlyPlayedFullContext() {
    let q = QueueService()
    let ctx = [snap("a"), snap("b"), snap("c")]
    q.play(ctx[1], context: ctx, from: .recently)
    #expect(q.items.count == 3)
    #expect(q.currentIndex == 1)
    #expect(q.current()?.track.title == "b")
    let n = q.next()
    #expect(n?.track.title == "c")
}

@Test("playlist context of three snaps positions last tap at index 2")
func playlistFullContext() {
    let q = QueueService()
    let ctx = [snap("a"), snap("b"), snap("c")]
    q.play(ctx[2], context: ctx, from: .playlist)
    #expect(q.items.count == 3)
    #expect(q.currentIndex == 2)
    #expect(q.current()?.track.title == "c")
}
```

- [ ] **Step 2: Write the failing PlaybackService test**

Append to `PlaybackServiceTests.swift` (reuse `snap(_:path:)` and `makePlayback()` / `makeSilentWav`):

```swift
@Test("playTrack from recently with three-item context advances to next snap")
func recentlyPlayedNextAdvances() async throws {
    let wav = FileManager.default.temporaryDirectory
        .appending(path: "muses-pb-recent-\(UUID().uuidString).wav")
    try makeSilentWav(at: wav, seconds: 1)
    let a = snap("a", path: wav.path)
    let b = snap("b", path: wav.path)
    let c = snap("c", path: wav.path)
    let svc = makePlayback()
    svc.playTrack(b, context: [a, b, c], from: .recently)
    try await Task.sleep(for: .milliseconds(100))
    #expect(svc.state.track?.title == "b")
    svc.next()
    try await Task.sleep(for: .milliseconds(100))
    #expect(svc.state.track?.title == "c")
}
```

- [ ] **Step 3: Run the new tests — they should pass already at the service layer**

```bash
swift test --no-parallel --filter QueueServiceTests.recentlyPlayedFullContext
swift test --no-parallel --filter QueueServiceTests.playlistFullContext
swift test --no-parallel --filter PlaybackServiceTests.recentlyPlayedNextAdvances
```

Expected: **PASS**. These tests lock the existing `QueueService.play` contract so a later regression cannot silently go back to one-item context. They do **not** prove the view call sites yet.

- [ ] **Step 4: Fix the three view call sites**

`HomeView.swift` Recently Played (~223–226):

```swift
RecentTrackCard(snap: snap) {
    playback.playTrack(snap, context: recentlyPlayed, from: .recently)
}
```

`PlaylistDetailView.swift` `PlaylistTrackRow` play button (~163–165). The row cannot see `playFromList`. Change the button to call a passed-in play closure, **or** replace the inline `playTrack` with a callback from the parent.

Preferred (minimal): add `var onPlay: () -> Void` to `PlaylistTrackRow` and wire:

```swift
// PlaylistDetailView ForEach
PlaylistTrackRow(item: item, onRemove: { removeItem(item) }, onPlay: { playFromList(item) })
```

```swift
// PlaylistTrackRow play button
Button(action: onPlay) {
    Image(systemName: "play.fill")
        .foregroundStyle(BrandColors.magenta)
}
.buttonStyle(.plain)
```

Do **not** add `.onTapGesture { play(...) }` on the playlist row.

`YouTubeImportsView.swift` `YouTubeImportItemRow` (~295–299). The parent already has the import’s items. Pass the visible snaps in and play the full list:

```swift
Button {
    if let t = item.track {
        let snap = TrackSnapshot(from: t)
        playback.playTrack(snap, context: visibleSnaps, from: .import)
    }
} label: { Image(systemName: "play.fill") }
```

Where `visibleSnaps` is the import’s current item snapshots (same array `playItem` uses in `YouTubeAlbumDetailView`). If the row does not have that array, add `let context: [TrackSnapshot]` to `YouTubeImportItemRow`.

- [ ] **Step 5: Grep done-bar (PR 2 column)**

```bash
rg -n 'context: \[snap\]' Muses/Sources/Muses
```

**Not allowed:** `HomeView` Recently Played; `PlaylistTrackRow` in-row Play; `YouTubeImportItemRow` in-row Play.

**Allowed remaining:** YouTube discovery/search `importAsTrack`; History; Inbox; Queue history Replay; `MusesApp` one-shot/deep-link; `NewView` situational (~94) until Task 7.

- [ ] **Step 6: Re-run tests and commit**

```bash
swift test --no-parallel --filter 'QueueServiceTests|PlaybackServiceTests'
git add Muses/Tests/MusesTests/QueueServiceTests.swift \
        Muses/Tests/MusesTests/PlaybackServiceTests.swift \
        Muses/Sources/Muses/Features/HomeView.swift \
        Muses/Sources/Muses/Features/Playlist/PlaylistDetailView.swift \
        Muses/Sources/Muses/Features/YouTube/YouTubeImportsView.swift
git commit -m "fix: play recently played and playlist/import rows with full list context"
```

---

### Task 3: Search overlay, Escape, shortcut copy, rail Retry

**Files:**
- Modify: `Muses/Sources/Muses/Features/SidebarView.swift` (~29–30)
- Modify: `Muses/Sources/Muses/App/RootView.swift` (~55–58)
- Modify: `Muses/Sources/Muses/Features/Search/GlobalSearchView.swift`
- Modify: `Muses/Sources/Muses/Features/Queue/QueueDrawerView.swift`
- Modify: `Muses/Sources/Muses/Features/LibraryView.swift` (~28, ~129)
- Modify: `Muses/Sources/Muses/Features/HomeView.swift` (discovery + Top Picks)

**Interfaces:**
- Consumes: `Notification.Name.musesFocusSearch` (already posted by ⌘F in `MusesApp`); `RootView.onReceive` already toggles `showSearch`; `GlobalSearchView.close()` already `search.reset(); isPresented = false`; `HomeDiscoveryService.reload()`; `HomeView.loadTrending()`
- Produces: Search is overlay-only; Escape dismisses Search/Queue; failed rails have Retry; empty loaded rails hide including header

- [ ] **Step 1: Sidebar Search becomes a Button with no tag**

In `SidebarView` top `Section`, replace the tagged Search `Label` with:

```swift
Button {
    NotificationCenter.default.post(name: .musesFocusSearch, object: nil)
} label: {
    Label(tr("Search", "搜索"), systemImage: "magnifyingglass")
}
.buttonStyle(.plain)
```

Do **not** add `.tag(SidebarSection.search)`. Do **not** set `selection = .search`.

- [ ] **Step 2: RootView `.search` never renders EmptyView**

Replace the `.search` case:

```swift
case .search:
    HomeView(selection: $section, selectedAlbum: $selectedAlbum)
```

Keep `SidebarSection.search` on the enum. Do not set `section = .search` anywhere. Confirm `onReceive(.musesFocusSearch)` still only toggles `showSearch`.

- [ ] **Step 3: Escape on Search**

On `GlobalSearchView`’s root `ZStack` **and** on the search `TextField`:

```swift
.onExitCommand { close() }
```

On the `TextField` also add:

```swift
.onKeyPress(.escape) {
    close()
    return .handled
}
```

Do **not** use Escape to clear the query. Do **not** add a global key monitor.

- [ ] **Step 4: Escape on Queue**

On `QueueDrawerView`’s root container (not inside the rename `alert`):

```swift
.onExitCommand { isPresented = false }
```

- [ ] **Step 5: Shortcut copy**

`LibraryView` empty albums (~28):

```swift
tr("Open Search (⌘F) and tap + to import a music folder, or drag files into the window",
   "打开搜索(⌘F)点击 + 导入音乐文件夹,或拖拽文件到窗口")
```

`SongsListView` empty (~129):

```swift
tr("Open Search (⌘F) and tap + to import a music folder",
   "打开搜索(⌘F)点击 + 导入音乐文件夹")
```

Grep leftover `⌘K` in empty-state copy (not in Queue labels):

```bash
rg -n '⌘K' Muses/Sources/Muses/Features/LibraryView.swift
```

Expected: no Search-import copy still saying ⌘K.

- [ ] **Step 6: Home rail Retry + empty collapse**

Add on `HomeView`:

```swift
@State private var retryingIDs: Set<String> = []
```

In `discoverySection`:

- `.failed`: keep `SectionHeader`. Show the message (`msg ?? tr("Couldn’t load this section", "无法加载该区段")`) plus:

```swift
Button(tr("Retry", "重试")) {
    retryingIDs.insert(section.id)
    homeDiscovery.reload()
}
.buttonStyle(.plain)
```

- While `homeDiscovery.isRefreshing && retryingIDs.contains(section.id)`, show the existing skeleton `ResponsiveCarousel` instead of the error caption.
- `.onChange(of: homeDiscovery.isRefreshing)`: when it becomes `false`, `retryingIDs.removeAll()`.
- `.loaded` / `.idle` with `section.items.isEmpty`: return `EmptyView()` for the **entire** `discoverySection` (no `SectionHeader`).

`topPicksSection` error branch: keep header, add `Button(tr("Retry", "重试")) { loadTrending() }`.

Do **not** add `retrySection(id:)` to `HomeDiscoveryService`.

- [ ] **Step 7: Build and grep**

```bash
swift build --target Muses
rg -n 'EmptyView\(\)' Muses/Sources/Muses/App/RootView.swift
rg -n 'SidebarSection.search' Muses/Sources/Muses/Features/SidebarView.swift
```

Expected: `RootView` `.search` is not `EmptyView`. `SidebarView` has no `.tag(SidebarSection.search)`.

- [ ] **Step 8: Rendered verification (required; do not ship on source inspection)**

Launch the app (`make app` or the already-packaged `build/Muses.app`).

1. Click sidebar Search — overlay opens; current detail (Home) stays under the scrim; sidebar highlight does **not** move to Search.
2. ⌘F still opens Search.
3. Search field focused, type a query, press Escape — overlay dismisses; it does not merely clear the field. Repeat with empty query.
4. Open Queue (⌘K). Escape closes the drawer. Open rename-group alert if present — Escape closes the alert, not the drawer.
5. If a Home discovery section is failed, Retry shows the skeleton then either items or the error again.

- [ ] **Step 9: Commit**

```bash
git add Muses/Sources/Muses/Features/SidebarView.swift \
        Muses/Sources/Muses/App/RootView.swift \
        Muses/Sources/Muses/Features/Search/GlobalSearchView.swift \
        Muses/Sources/Muses/Features/Queue/QueueDrawerView.swift \
        Muses/Sources/Muses/Features/LibraryView.swift \
        Muses/Sources/Muses/Features/HomeView.swift
git commit -m "fix: Search overlay, Escape, rail Retry, and ⌘F empty-state copy"
```

---

### Task 4: ArtworkSource identity + ImageLoader local path

**Files:**
- Modify: `Muses/Sources/Muses/Features/NowPlaying/ArtworkSource.swift`
- Modify: `Muses/Sources/Muses/Infrastructure/ImageLoader.swift`
- Modify: `Muses/Sources/Muses/Features/NowPlaying/NowPlayingView.swift` (`extractGradient`)
- Test: `Muses/Tests/MusesTests/ArtworkCacheTests.swift`
- Test: `Muses/Tests/MusesTests/PhaseP3EnrichmentTests.swift` (~251–292)

**Interfaces:**
- Consumes: `ArtworkCache.default.path(forHash:)`, existing `ImageLoader.load(_:)`, `CachedAsyncImage`
- Produces:

```swift
enum ArtworkSource: Equatable, Sendable {
    case localFile(URL)
    case remote(URL)
    case placeholder

    static func resolve(for track: TrackSnapshot?) -> ArtworkSource
    static func resolve(for album: BrowsableAlbum) -> ArtworkSource
    static func resolve(for artist: BrowsableArtist) -> ArtworkSource
    static func localHash(_ hash: String?) -> ArtworkSource

    /// Blocking decode for detached palette only. Never call from `body`.
    func loadNSImage() -> NSImage?
}

struct ArtworkView: View {
    let source: ArtworkSource
    var cornerRadius: CGFloat = 12
    var glyphSize: CGFloat = 80
    var clipCircle: Bool = false
    var targetSize: CGFloat = 200
}

extension ImageLoader {
    func cachedImage(for url: URL, targetSize: CGFloat) -> NSImage?
    func loadLocal(url: URL, targetSize: CGFloat) -> Task<NSImage?, Never>
}
```

- [ ] **Step 1: Write failing ArtworkSource tests**

Append to `ArtworkCacheTests.swift` (or add a focused `@Suite` in that file):

```swift
@Test("localHash missing hash is placeholder; present hash is localFile")
func artworkSourceLocalHash() {
    #expect(ArtworkSource.localHash(nil) == .placeholder)
    #expect(ArtworkSource.localHash("") == .placeholder)
    // A hash with no file on disk still yields localFile only if ArtworkCache returns a path.
    // If path(forHash:) is nil → placeholder.
    let missing = ArtworkSource.localHash("definitely-not-a-real-hash-\(UUID().uuidString)")
    if ArtworkCache.default.path(forHash: "definitely-not-a-real-hash") == nil {
        #expect(missing == .placeholder)
    }
}
```

Update `PhaseP3EnrichmentTests.artworkSourceResolution` so any future `.cached` match would fail to compile. The existing `.remote` / `.placeholder` cases must still compile against `.localFile` / `.remote` / `.placeholder`.

- [ ] **Step 2: Run tests — expect compile failure on `.cached`**

```bash
swift test --no-parallel --filter artworkSourceResolution
```

Expected: **FAIL to compile** if any test or app site still switches on `.cached`. If the enum is not yet changed, write the enum next (Step 3) and fix compile sites in this task’s source files only. Remaining feature `body` compile breaks are Task 5.

- [ ] **Step 3: Change the enum and resolve helpers**

Replace `ArtworkSource` cases and `resolve` methods. Do **not** decode in `resolve`.

```swift
enum ArtworkSource: Equatable, Sendable {
    case localFile(URL)
    case remote(URL)
    case placeholder

    static func localHash(_ hash: String?) -> ArtworkSource {
        guard let hash, !hash.isEmpty,
              let url = ArtworkCache.default.path(forHash: hash) else {
            return .placeholder
        }
        return .localFile(url)
    }

    static func resolve(for track: TrackSnapshot?) -> ArtworkSource {
        guard let track else { return .placeholder }
        let local = localHash(track.artworkHash)
        if case .localFile = local { return local }
        if let vid = track.youTubeId,
           let url = URL(string: "https://i.ytimg.com/vi/\(vid)/hqdefault.jpg") {
            return .remote(url)
        }
        if let urlStr = track.artworkUrl, let url = URL(string: urlStr) {
            return .remote(url)
        }
        return .placeholder
    }

    func loadNSImage() -> NSImage? {
        switch self {
        case .localFile(let url):
            return NSImage(contentsOf: url)
        case .remote(let url):
            guard let data = try? Data(contentsOf: url) else { return nil }
            return NSImage(data: data)
        case .placeholder:
            return nil
        }
    }
}
```

Keep `resolve(for album: BrowsableAlbum)` / `resolve(for artist: BrowsableArtist)` fallbacks from today’s file (hash → URL → first YT thumb). Return `.localFile` instead of `.cached(NSImage(byReferencing:))`.

- [ ] **Step 4: ImageLoader local bounded decode**

Add a size-aware memory key and local loader. Do **not** send ArtworkCache `file://` URLs through `URLSession.shared.data(from:)` as the default path.

```swift
func cacheKey(url: URL, targetSize: CGFloat) -> String {
    "\(url.absoluteString)#\(Int(targetSize.rounded()))"
}

func cachedImage(for url: URL, targetSize: CGFloat) -> NSImage? {
    memory.object(forKey: cacheKey(url: url, targetSize: targetSize) as NSString)
}

func loadLocal(url: URL, targetSize: CGFloat) -> Task<NSImage?, Never> {
    let key = cacheKey(url: url, targetSize: targetSize)
    if let hit = memory.object(forKey: key as NSString) {
        return Task { hit }
    }
    if let existing = inFlight[key] { return existing }
    let task = Task<NSImage?, Never> {
        let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let src = NSImage(contentsOf: url) else { return nil }
            let scale: CGFloat = 2
            let px = max(targetSize * scale, 1)
            let newSize = NSSize(width: px, height: px)
            let dest = NSImage(size: newSize)
            dest.lockFocus()
            src.draw(in: NSRect(origin: .zero, size: newSize),
                     from: NSRect(origin: .zero, size: src.size),
                     operation: .copy, fraction: 1)
            dest.unlockFocus()
            return dest
        }.value
        if let img {
            await MainActor.run {
                self.memory.setObject(img, forKey: key as NSString, cost: Int(targetSize * targetSize * 4))
            }
        }
        return img
    }
    inFlight[key] = task
    return task
}
```

Clear `inFlight[key]` in a `defer` on the main actor, same as `load(_:)`.

Keep existing `load(_ url: URL)` for remote / `CachedAsyncImage`.

- [ ] **Step 5: Rewrite ArtworkView**

```swift
struct ArtworkView: View {
    let source: ArtworkSource
    var cornerRadius: CGFloat = 12
    var glyphSize: CGFloat = 80
    var clipCircle: Bool = false
    var targetSize: CGFloat = 200

    var body: some View {
        Group {
            switch source {
            case .localFile(let url):
                LocalArtworkImage(url: url, targetSize: targetSize)
            case .remote(let url):
                CachedAsyncImage(
                    url: url,
                    content: { $0.resizable().scaledToFill() },
                    placeholder: { placeholder }
                )
            case .placeholder:
                placeholder
            }
        }
        .frame(width: targetSize, height: targetSize)
        .clipped()
        .clipShape(clipCircle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius)))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: clipCircle ? targetSize / 2 : cornerRadius)
            .fill(BrandColors.surface)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: glyphSize))
                    .foregroundStyle(BrandColors.textSecondary.opacity(0.5))
            )
    }
}
```

`LocalArtworkImage` is a tiny view: first frame from `ImageLoader.shared.cachedImage(for:targetSize:)`; on miss start `loadLocal`, store the result in `@State`, cancel on disappear, ignore the result if `url` changed.

If `AnyShape` is awkward on macOS 14, branch with `@ViewBuilder` instead of `AnyShape`.

- [ ] **Step 6: Move Now Playing extractGradient I/O off-main**

`NowPlayingView.extractGradient()` currently switches `.cached` on the main actor. Change to:

```swift
private func extractGradient() {
    let source = ArtworkSource.resolve(for: playback.state.track)
    let expectedID = playback.state.track?.id
    Task { @MainActor in
        let img = await Task.detached(priority: .userInitiated) {
            source.loadNSImage()
        }.value
        guard playback.state.track?.id == expectedID, let img else { return }
        let colors = AlbumArtworkExtractor.dominantColors(img, count: 4)
        gradient = colors.map { Color(nsColor: $0) } + [BrandColors.background]
    }
}
```

- [ ] **Step 7: Run ArtworkSource tests and commit**

```bash
swift test --no-parallel --filter 'artworkSourceResolution|artworkSourceLocalHash'
```

Expected: PASS. App target may still fail to compile at remaining `.cached` / body-decode sites — that is Task 5. If `swift test` cannot link because the app target fails, proceed immediately to Task 5 in the same working tree **but commit this task’s files only after Task 5 compiles**, or land 4+5 as two commits once green.

If the test target compiles independently, commit Task 4 now:

```bash
git add Muses/Sources/Muses/Features/NowPlaying/ArtworkSource.swift \
        Muses/Sources/Muses/Infrastructure/ImageLoader.swift \
        Muses/Sources/Muses/Features/NowPlaying/NowPlayingView.swift \
        Muses/Tests/MusesTests/ArtworkCacheTests.swift \
        Muses/Tests/MusesTests/PhaseP3EnrichmentTests.swift
git commit -m "fix: ArtworkSource identity and bounded ImageLoader local decode"
```

If compile is blocked by call sites, skip this commit and finish Task 5 first, then make **two** commits (decode types, then call-site swaps) if the diff is still separable; otherwise one commit titled `fix: ArtworkSource identity; decode off view body`.

---

### Task 5: Display-only ArtworkView swaps (no card-type deletion)

**Files:** display-only swap to `ArtworkView(source:targetSize:)` — **do not delete** these types:

| File | Site |
|---|---|
| `Features/NowPlaying/CoverArtModeView.swift` | pass-through `ArtworkSource` |
| `Features/NowPlaying/VinylModeView.swift` | pass-through |
| `Features/NowPlaying/UpNextPreview.swift` ~34 | already `ArtworkView` |
| `Features/MiniPlayer/MiniPlayerView.swift` ~19 | already `ArtworkView` |
| `Features/Browse/BrowsableViews.swift` | already `ArtworkView` |
| `Features/PlayerBar.swift` ~49 | `NSImage(byReferencing:)` → `ArtworkView` |
| `Features/Search/GlobalSearchView.swift` ~266/296/319 | decode in body → `ArtworkView` |
| `Features/HomeView.swift` | hero ~151, `RecentTrackCard` ~457; `updateGradientAsync` stays detached |
| `Features/LibraryView.swift` | `AlbumCard` ~80, `SongRow` ~263 |
| `Features/Artist/ArtistsView.swift` ~105 | `ArtistCard` |
| `Features/Artist/ArtistDetailView.swift` | header ~59; `extractGradient` ~136 detached |
| `Features/AlbumDetailView.swift` | hero ~114; `extractGradient` ~156 detached |
| `Features/NewView.swift` ~100 | situational card |
| `Features/Shared/DiscoveryCard.swift` ~56 | type stays |
| `Features/Shared/SongCompactRow.swift` ~59 | unused type; still no body decode |

**Interfaces:**
- Consumes: `ArtworkSource.localHash`, `ArtworkSource.resolve(for:)`, `ArtworkView`
- Produces: zero `NSImage(byReferencing:)` / `NSImage(contentsOf:)` in feature view `body`

- [ ] **Step 1: Grep the starting set**

```bash
rg -n 'NSImage\(byReferencing:|NSImage\(contentsOf:|\.cached\(' Muses/Sources/Muses
```

Keep this list; every feature-`body` hit must be gone at the end of this task.

- [ ] **Step 2: PlayerBar artwork**

Replace `PlayerBar.artwork` with:

```swift
private var artwork: some View {
    ArtworkView(
        source: ArtworkSource.resolve(for: playback.state.track),
        cornerRadius: 6,
        glyphSize: 20,
        targetSize: 52
    )
}
```

Keep `.onTapGesture { onArtworkTap() }` on the 52pt frame. No matched geometry yet.

- [ ] **Step 3: Search overlay rows**

Replace each `NSImage(byReferencing:)` / `contentsOf` block in `GlobalSearchView` with `ArtworkView(source: ArtworkSource.localHash(...) or .resolve(for:), targetSize: 40, glyphSize: 16)`. Keep private row types. Do **not** convert them to `SongObjectView`.

- [ ] **Step 4: Cards and heroes (types stay)**

Pattern for a local hash:

```swift
ArtworkView(
    source: ArtworkSource.localHash(album.artworkHash),
    cornerRadius: 8,
    glyphSize: 32,
    targetSize: 200
)
```

Artist header/card: `clipCircle: true`, size 200 or 180.

Album detail hero: `targetSize: 240`, `cornerRadius: 12`.

`DiscoveryCard` / `RecentTrackCard` / `NewView`: `targetSize` = their current frame (150 / 120 / existing).

Album/artist `extractGradient` that uses `NSImage(contentsOf:)` on `onAppear` must move into `Task.detached` + identity check (same shape as HomeView `updateGradientAsync`). Those `contentsOf:` calls are legal **only** inside the detached helper.

- [ ] **Step 5: Done-bar grep**

```bash
rg -n 'NSImage\(byReferencing:|NSImage\(contentsOf:|\.cached\(' Muses/Sources/Muses
```

**Allowed leftovers:** `ImageLoader` local path, detached `extractGradient` / `updateGradientAsync` / `ArtworkSource.loadNSImage()`, Settings/About/Sidebar logos, tests/fixtures.

**Not allowed:** any of the files in the table above, inside `var body`.

- [ ] **Step 6: Build, test, commit**

```bash
swift test --no-parallel --filter 'artworkSourceResolution|artworkSourceLocalHash|PhaseP4GlassTests'
git add Muses/Sources/Muses
git commit -m "fix: ArtworkView display path; no NSImage decode in view body"
```

Do not delete `AlbumCard` / `DiscoveryCard` / `RecentTrackCard` / `ArtistCard` / `SongCompactRow` yet.

---

### Task 6: Shared music-object types (no hover, no swap)

**Files:**
- Create: `Muses/Sources/Muses/Features/Shared/MusicObjectMetrics.swift`
- Create: `Muses/Sources/Muses/Features/Shared/AlbumObject.swift`
- Create: `Muses/Sources/Muses/Features/Shared/ArtistObject.swift`
- Create: `Muses/Sources/Muses/Features/Shared/SongObject.swift`
- Create: `Muses/Sources/Muses/Features/Shared/HeroObject.swift`

**Interfaces:**
- Consumes: `ArtworkView`, `ArtworkSource`, `BrandColors`, `tr`
- Produces: the types later tasks import. `showsHoverPlay` defaults **false**. No `onHover` yet.

- [ ] **Step 1: Metrics**

Create `MusicObjectMetrics.swift`:

```swift
import CoreGraphics
import Foundation

enum MusicObjectMetrics {
    static let albumRail: CGFloat = 160
    static let albumGrid: CGFloat = 200
    static let albumHero: CGFloat = 240
    static let artistGrid: CGFloat = 200
    static let artistHeader: CGFloat = 180
    static let songArtMin: CGFloat = 44
    static let songArtMax: CGFloat = 48
    static let playerBarArt: CGFloat = 52
    static let albumCornerRail: CGFloat = 8
    static let albumCornerHero: CGFloat = 12
    static let hoverLift: CGFloat = 4
    static let hoverDuration: TimeInterval = 0.15
}
```

- [ ] **Step 2: Album object**

Create `AlbumObject.swift` with the spec signature:

```swift
import SwiftUI

enum AlbumObjectRole {
    case browse
    case play
}

struct AlbumObjectView: View {
    let title: String
    let subtitle: String
    let artwork: ArtworkSource
    var size: CGFloat = MusicObjectMetrics.albumGrid
    var cornerRadius: CGFloat = MusicObjectMetrics.albumCornerRail
    var role: AlbumObjectRole = .browse
    var isNowPlaying: Bool = false
    var showsHoverPlay: Bool = false
    var onSelect: () -> Void
    var onPlay: () -> Void

    var body: some View {
        Button(action: {
            switch role {
            case .browse: onSelect()
            case .play: onPlay()
            }
        }) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    ArtworkView(source: artwork, cornerRadius: cornerRadius,
                                glyphSize: size > 180 ? 40 : 28, targetSize: size)
                    if isNowPlaying {
                        Image(systemName: "speaker.wave.2")
                            .font(.caption)
                            .padding(6)
                            .foregroundStyle(BrandColors.textPrimary)
                    }
                }
                Text(title)
                    .font(size >= 200 ? .subheadline : .caption)
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(BrandColors.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) — \(subtitle)")
    }
}
```

Leave a `showsHoverPlay` parameter unused until Task 8 (do not install hover). No glass. No neon ring.

- [ ] **Step 3: Artist object**

```swift
struct ArtistObjectView: View {
    let name: String
    let detail: String
    let artwork: ArtworkSource
    var size: CGFloat = MusicObjectMetrics.artistGrid
    var isNowPlaying: Bool = false
    var showsHoverPlay: Bool = false
    var onSelect: () -> Void
    var onPlay: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    ArtworkView(source: artwork, glyphSize: 40,
                                clipCircle: true, targetSize: size)
                    if isNowPlaying {
                        Image(systemName: "speaker.wave.2")
                            .foregroundStyle(BrandColors.textPrimary)
                    }
                }
                Text(name).font(.subheadline).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(BrandColors.textSecondary).lineLimit(1)
            }
            .frame(width: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name) — \(detail)")
    }
}
```

- [ ] **Step 4: Song object**

Implement `SongObjectView` with every accessory from the spec (`albumTitle`, `durationLabel`, `indexLabel`, `isLossless`, `showLocalBadge`, `isLiked` / `onToggleLike`, `onRemove`, `onQueue`, `onInbox`, `onOverflow`). Art size `MusicObjectMetrics.songArtMin`.

Click handling in this task: call `onSelect()` on tap. Do **not** auto-play. Call sites decide select-and-play vs select-only in Task 7.

Selected row: `BrandColors.surface` background, 6pt corner. Now-playing: `speaker.wave.2` plus primary title. Hi-Res: small `tr("Hi-Res", "Hi-Res")` caption if `isLossless`. Local badge: `tr("Local", "本地")` if `showLocalBadge`. Heart button only when `isLiked != nil`.

The primitive must **not** read `playback`. No `.trackContextMenu` inside the type.

- [ ] **Step 5: Hero object**

`HeroObjectView(title:subtitle:metadata:artwork:gradient:onOpen:onPlay:)` — large art (`albumHero` 240), title, subtitle, existing Play button (`tr("Play", "播放")`), artwork gradient behind. Click on art/title → `onOpen`. Play button → `onPlay`. This replaces the Home hero block visually in Task 7.

- [ ] **Step 6: Build and commit**

```bash
swift build --target Muses
git add Muses/Sources/Muses/Features/Shared/MusicObjectMetrics.swift \
        Muses/Sources/Muses/Features/Shared/AlbumObject.swift \
        Muses/Sources/Muses/Features/Shared/ArtistObject.swift \
        Muses/Sources/Muses/Features/Shared/SongObject.swift \
        Muses/Sources/Muses/Features/Shared/HeroObject.swift
git commit -m "feat: Album, Artist, Song, and Hero object primitives"
```

---

### Task 7: Swap call sites and delete old cards

**Files:**
- Modify: `HomeView.swift`, `NewView.swift`, `LibraryView.swift` (including `SongsListView` / `SongRow` / `LikedView`), `RecentlyView.swift`, `PinsView.swift`, `PlaylistsView.swift`, `ArtistsView.swift`, `ArtistDetailView.swift`, `AlbumDetailView.swift`, `PlaylistDetailView.swift`, `Browse/BrowsableViews.swift`, `YouTubeAlbumDetailView.swift`, `YouTubeImportsView.swift` (`YouTubeImportItemRow` only)
- Delete after swap: `DiscoveryCard.swift`, `SongCompactRow.swift`, and the in-file types `AlbumCard`, `ArtistCard`, `RecentTrackCard`, `TrackRow`, `PlaylistCard` (if fully replaced)
- **Do not** convert `YouTubeImportCard`
- **Do not** convert `HomeDiscoveryCardView` / `YouTubeTrendingCard` (keep 16:9 + one-item `importAsTrack`)
- **Do not** convert Search overlay rows

**Interfaces:**
- Consumes: Task 6 types; `library.tracks(in:)`, `library.tracks(byArtist:)`, `playFromList`, `browsable.trackSnapshots`
- Produces: every listed surface renders a shared object; `showsHoverPlay = false`

**Click / play matrix (must match spec §2):**

| Surface | Click | Play path |
|---|---|---|
| Album / artist rails & grids | `onSelect` opens detail | `onPlay` unused until Task 8 hover |
| Recently Played / New track rails | `role: .play` → `onPlay` | full `recentlyPlayed` / section snaps |
| Songs list | select only (`List` selection) | double-click / Return / context-menu → visible list, `from: .songs` |
| Album / artist / Liked detail | `onSelect` **and** `onPlay` both play visible list | `from: .album` / `.artist` / `.songs` |
| Playlist / YouTube-import rows | `onSelect` selects only | Play control → `playFromList` / `allSnaps` |

- [ ] **Step 1: Home rails**

`horizontalSection`: replace `DiscoveryCard` with

```swift
AlbumObjectView(
    title: album.title,
    subtitle: album.albumArtist,
    artwork: ArtworkSource.localHash(album.artworkHash),
    size: MusicObjectMetrics.albumRail,
    role: .browse,
    onSelect: { selectedAlbum = album },
    onPlay: { playAlbum(album) }
)
```

Recently Played:

```swift
AlbumObjectView(
    title: snap.title,
    subtitle: snap.artist,
    artwork: ArtworkSource.resolve(for: snap),
    size: MusicObjectMetrics.albumRail,
    role: .play,
    onSelect: {},
    onPlay: { playback.playTrack(snap, context: recentlyPlayed, from: .recently) }
)
```

Hero: replace the custom hero block with `HeroObjectView`, wiring `onOpen` → `selectedAlbum = album`, `onPlay` → `playAlbum(album)`, gradient from existing `heroGradient`.

`YouTubeImportCardSmall` → `AlbumObjectView` 160 `.browse`, `onSelect` opens the import, `onPlay` plays import snaps `from: .import`.

All Albums grid → `AlbumObjectView` size `albumGrid`.

- [ ] **Step 2: Library / Pins / Recently / Playlists / Artists**

Same `AlbumObjectView` / `ArtistObjectView` swap. Playlists browse + Pins playlists: square Album object 160–200; **reapply** pin/delete `.contextMenu` at the call site. Do not put pin/delete inside the primitive.

`ArtistsView.playArtist` stays on the context menu (including shuffle). `onPlay` on the object (Task 8) will call the non-shuffle path.

- [ ] **Step 3: Song rows**

Replace `SongRow` / `TrackRow` / `PlaylistTrackRow` / `YouTubeAlbumTrackRow` / `YouTubeImportItemRow` with `SongObjectView` + accessories + `.trackContextMenu` at the call site.

`LikedView`: swap `TrackRow` so deleting `TrackRow` still compiles. Do **not** add `LikedView` to the sidebar.

`SongsListView`: bind `List(..., selection:)` to `@State private var selectedSongID: UUID?`. Single click sets selection. Keep `.onTapGesture(count: 2)` or equivalent to play the **visible sorted/filtered** list.

Playlist: row `onSelect` sets selection only. Play button / context menu call `playFromList`. Keep `.onMove` and remove.

- [ ] **Step 4: New situational rails**

Replace one-item `context: [snap], from: .songs` with the **section’s** snapshot array and `AlbumObjectView` role `.play`.

- [ ] **Step 5: Delete old types**

Delete `DiscoveryCard.swift`, `SongCompactRow.swift`, and the replaced in-file structs. Grep:

```bash
rg -n 'struct AlbumCard|struct ArtistCard|struct RecentTrackCard|struct TrackRow|struct SongRow|struct PlaylistCard|struct DiscoveryCard|struct SongCompactRow|struct PlaylistTrackRow' Muses/Sources/Muses
```

Expected: no remaining production definitions (wrappers only if a one-line alias is still compiling; delete those too before commit).

- [ ] **Step 6: Grep done-bar (PR 3b column)**

```bash
rg -n 'context: \[snap\]' Muses/Sources/Muses
```

**Allowed:** YouTube discovery/search `importAsTrack`; History; Inbox; Queue history Replay; `MusesApp` one-shot.

**Not allowed:** `NewView` situational; `YouTubeImportItemRow`; Home Recently Played; playlist in-row Play.

- [ ] **Step 7: Test, build, commit**

```bash
swift test --no-parallel
git add -u Muses/Sources/Muses
git commit -m "feat: swap browsing surfaces onto Album, Artist, Song, Hero objects"
```

---

### Task 8: Hover Play, now-playing identity, row selection

**Files:**
- Create: `Muses/Sources/Muses/Features/Shared/HoverPlayButton.swift`
- Create: `Muses/Sources/Muses/Features/Shared/NowPlayingMark.swift`
- Create: `Muses/Sources/Muses/Features/Shared/MusesMotion.swift`
- Modify: the four object files
- Modify: parents that host grids/lists (`HomeView`, `LibraryView`, `ArtistsView`, `AlbumDetailView`, `ArtistDetailView`, `PlaylistDetailView`, YouTube album detail)

**Interfaces:**
- Consumes: `playback.state.track?.id`, `playback.state.isPlaying`, `library.track(by:)`, `MusicObjectMetrics.hoverLift` / `hoverDuration`
- Produces: hover Play on artwork; `NowPlayingMark`; parent-cached `playingAlbumID` / `playingArtistID`

- [ ] **Step 1: Motion tokens**

```swift
import SwiftUI

enum MusesMotion {
    static let hover: TimeInterval = 0.15
    static let overlay: TimeInterval = 0.20
    static let drawer: TimeInterval = 0.25
    static let nowPlayingMorph: TimeInterval = 0.32

    static func hoverAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: hover)
    }

    static func morphAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: nowPlayingMorph)
    }
}
```

- [ ] **Step 2: HoverPlayButton**

A 28–32pt circular control on the artwork, `play.fill`, `BrandColors.textPrimary` on a dim scrim. `.musesGlass(role: .floatingControl)` is allowed (chrome on the object, not a glass card). Accessibility: `tr("Play", "播放")`. Action calls `onPlay`.

- [ ] **Step 3: NowPlayingMark**

This view is the **only** object-level reader of playback:

```swift
struct NowPlayingMark: View {
    let itemID: UUID
    @Environment(PlaybackService.self) private var playback

    var body: some View {
        if playback.state.track?.id == itemID {
            Image(systemName: playback.state.isPlaying ? "speaker.wave.2" : "play.fill")
                .foregroundStyle(BrandColors.textPrimary)
        }
    }
}
```

Do **not** read `playback.state.position`. Album/artist collection identity is **not** computed here.

- [ ] **Step 4: Parent-cached collection IDs**

On each album/artist grid parent:

```swift
@State private var playingAlbumID: UUID?
@State private var playingArtistID: UUID?

private func refreshPlayingCollection() {
    let id = playback.state.track?.id
    playingAlbumID = id.flatMap { library.track(by: $0)?.album?.id }
    playingArtistID = id.flatMap { library.track(by: $0)?.artistRef?.id }
}
```

Call from `.onAppear` and `.onChange(of: playback.state.track?.id)`. Pass `isNowPlaying: album.id == playingAlbumID` into `AlbumObjectView`. `.play` rails compare snap id via `NowPlayingMark` / `isNowPlaying: playback.state.track?.id == snap.id` **inside a child**, not by reading `playback.state` in a 200-cell `ForEach` body.

- [ ] **Step 5: Wire hover on objects**

When `showsHoverPlay` is true:

- `@State private var hovering = false`
- `.onHover { hovering = $0 }`
- Lift: `.offset(y: hovering && !reduceMotion ? -MusicObjectMetrics.hoverLift : 0)` with `MusesMotion.hoverAnimation`
- Show `HoverPlayButton` on the artwork only
- Album `.browse`: hover Play → `onPlay` (play collection); click elsewhere → `onSelect`
- Album `.play`: both → `onPlay`
- Artist: hover Play → `onPlay`; click → `onSelect`
- Song: hover Play → `onPlay`; click → `onSelect` (parents already encode the matrix)
- Songs list rows: `showsHoverPlay` true, **no lift**

Set `showsHoverPlay: true` at Home/New/Library/Artists/detail/playlist/import call sites. Reduce Motion: no lift; Play control may still appear on hover.

- [ ] **Step 6: Songs list selection**

Ensure `List(selection: $selectedSongID)` is durable (highlight stays after click). Return key on the list plays the selected song with the visible list as context.

- [ ] **Step 7: Build, smoke, commit**

```bash
swift test --no-parallel
```

Rendered smoke: hover an album rail — Play appears, click Play starts the album, click the title/open area still opens detail. Playing album shows the mark. Songs list click selects; double-click plays.

```bash
git add Muses/Sources/Muses/Features/Shared \
        Muses/Sources/Muses/Features
git commit -m "feat: hover Play, now-playing identity, and song-row selection"
```

---

### Task 9: PlayerBar ↔ Now Playing artwork morph

**Files:**
- Create: `Muses/Sources/Muses/Features/Shared/ArtworkContinuity.swift`
- Modify: `Muses/Sources/Muses/App/RootView.swift`
- Modify: `Muses/Sources/Muses/Features/PlayerBar.swift`
- Modify: `Muses/Sources/Muses/Features/NowPlaying/NowPlayingView.swift`
- Modify: `CoverArtModeView.swift` / `VinylModeView.swift` only if needed to be host-renderable
- **Do not** edit `PlaybackService`, `NowPlayingManager`, vinyl rotation, or spectrum
- **Do not** implement card → detail matched geometry

**Interfaces:**
- Consumes: `MusesMotion.morphAnimation`, `ArtworkSource.resolve`, `CoverArtModeView`, `VinylModeView`
- Produces:

```swift
enum ArtworkContinuityID: Hashable {
    case liveCover(UUID)
    case album(UUID)          // reserved, unused
    case artist(UUID)         // reserved, unused
    case playlist(UUID)       // reserved, unused
    case youTubeImport(UUID)  // reserved, unused
}

struct ArtworkWorldNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}
```

- [ ] **Step 1: Continuity IDs + environment**

Create `ArtworkContinuity.swift` with the enum, the environment key, and:

```swift
struct CoverSlotPreferenceKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}
```

- [ ] **Step 2: RootView namespace and three NP layers**

On `RootView`:

```swift
@Namespace private var artworkWorld
@State private var coverSlot: Anchor<CGRect>?
```

Inject `.environment(\.artworkWorldNamespace, artworkWorld)` (name the key as implemented).

**Remove** `.transition(.opacity)` from the whole `NowPlayingView`.

When `showNowPlaying`:

1. **Back:** full-window `LinearGradient` + `BrandColors.scrim` (move the paint **out** of `NowPlayingView`). Fade with `MusesMotion.morphAnimation(reduceMotion:)`.
2. **Middle:** `NowPlayingView` chrome only — no gradient, no cover on the wide path. Chrome opacity fade. A `Color.clear` 480×480 slot in the left column uses `.anchorPreference(key: CoverSlotPreferenceKey.self, value: .bounds) { $0 }`.
3. **Front:** live-cover host, **slot-sized only**, positioned from the preference. Renders `CoverArtModeView` (then crossfades to `VinylModeView` after morph settles). `.matchedGeometryEffect(id: ArtworkContinuityID.liveCover(trackID), in: artworkWorld, isSource: showNowPlaying)`.

Skip the host (and skip matched geometry) when any of: `accessibilityReduceMotion`, `lyricsFullscreen`, no `track?.id`, **window width < 960**. On skip, PlayerBar keeps its art and `NowPlayingView` **keeps** in-scroll `centerContent`.

- [ ] **Step 3: PlayerBar token**

```swift
.matchedGeometryEffect(
    id: ArtworkContinuityID.liveCover(trackID),
    in: ns,
    isSource: !showNowPlaying
)
```

When morph is active, keep a 52×52 **placeholder** so the bar does not collapse. When morph is skipped, show art in place. Pass `showNowPlaying` / skip flag from `RootView` into `PlayerBar` (add a parameter; do not use a new service).

- [ ] **Step 4: NowPlayingView chrome split**

Wide path (`width >= 960` and not skipped): `centerContent` is `Color.clear.frame(width: 480, height: 480)` + anchor preference. No `CoverArtModeView` / `VinylModeView` inside this view.

Narrow path or skip: keep today’s `centerContent` inside `singleColumnLayout`’s `ScrollView`.

`extractGradient` can stay for other uses, but the **displayed** gradient on the wide path lives on the RootView environment overlay. Do not leave an opaque gradient in chrome.

Vinyl: after the still-cover morph settles (~`MusesMotion.nowPlayingMorph`), the **host** crossfades to `VinylModeView` if mode is `.vinyl`. Do **not** attach matched geometry to the rotating disc. Do **not** change vinyl math.

- [ ] **Step 5: Build and rendered verification**

```bash
swift test --no-parallel
```

Rendered (wide window ≥ 960): tap PlayerBar art — cover morphs into Now Playing; chrome/gradient fade; chevron morphs back. Reduce Motion: no morph. Resize below 960: no morph, in-scroll cover remains. Lyrics-fullscreen: no cover host. Vinyl mode: still cover morphs, then disc crossfade.

- [ ] **Step 6: Commit**

```bash
git add Muses/Sources/Muses/Features/Shared/ArtworkContinuity.swift \
        Muses/Sources/Muses/App/RootView.swift \
        Muses/Sources/Muses/Features/PlayerBar.swift \
        Muses/Sources/Muses/Features/NowPlaying
git commit -m "feat: PlayerBar to Now Playing artwork morph"
```

---

### Task 10: Home/New polish and rendered QA

**Files:**
- Modify: `HomeView.swift`, `NewView.swift`, object metrics/type only if rail titles need the spec §5.8 bump
- Create: `artifacts/artwork-world-qa-2026-08-18/` (screenshots + `screenshot-catalog.md`)

**Interfaces:**
- Consumes: objects + morph from Tasks 6–9
- Produces: type-scale polish; QA catalog. **No new product behavior.**

- [ ] **Step 1: Type scale**

Home/New rail titles use the existing `SectionHeader`. If rail card titles are still `.caption` on 160pt art, bump to `.subheadline` on the Album object when `size >= 160` (already in Task 6 if you used that cutoff). Hero remains the Media Environment; do not steal Now Playing theatrics.

- [ ] **Step 2: Capture the catalog**

Create `artifacts/artwork-world-qa-2026-08-18/screenshot-catalog.md` listing at least:

| File | Appearance | What it proves |
|---|---|---|
| `01-home-hero-dark.png` | dark, wide | hero + rails + hover Play |
| `02-home-retry.png` | dark | failed rail + Retry |
| `03-library-albums.png` | dark | 200pt Album objects |
| `04-album-detail.png` | dark | 240pt hero + playing row |
| `05-artist-detail.png` | dark | 180pt circle + albums |
| `06-songs-selection.png` | dark | durable row selection |
| `07-search-overlay.png` | dark | overlay from sidebar + ⌘F |
| `08-escape-search.png` | dark | focused non-empty query dismissed |
| `09-queue-escape.png` | dark | drawer dismiss |
| `10-morph-wide.png` | dark, ≥960 | PlayerBar → NP morph |
| `11-morph-skipped-narrow.png` | dark, <960 | no morph, in-scroll cover |
| `12-home-light.png` | light | light-mode contrast |

Also capture Reduce Motion (no morph / no lift) and Reduce Transparency.

- [ ] **Step 3: Final grep + tests**

```bash
rg -n 'context: \[snap\]' Muses/Sources/Muses
rg -n 'NSImage\(byReferencing:' Muses/Sources/Muses/Features
swift test --no-parallel
```

- [ ] **Step 4: Commit**

```bash
git add Muses/Sources/Muses/Features/HomeView.swift \
        Muses/Sources/Muses/Features/NewView.swift \
        artifacts/artwork-world-qa-2026-08-18
git commit -m "feat: artwork-world polish and rendered QA"
```

---

## Self-review

**Spec coverage**

| Spec requirement | Task |
|---|---|
| AGENTS.md motion + richer album/artist + no clone/card-glass/engine rewrite | 1 |
| Recently Played full list; playlist `playFromList`; import row context | 2 |
| ⌘F copy; Search overlay-only; Escape; rail Retry; empty collapse | 3 |
| `ArtworkSource` identity; ImageLoader local; NP gradient off-main | 4 |
| Every body-decode site → `ArtworkView`; no type deletion | 5 |
| Four primitives + metrics | 6 |
| Swap + delete old cards; click matrix; New section context; keep `YouTubeImportCard` / 16:9 discovery | 7 |
| Hover Play, `NowPlayingMark`, parent-cached album/artist IDs, Songs selection | 8 |
| RootView 3-layer morph; skip <960 / Reduce Motion / lyrics-fullscreen; host owns cover+vinyl; no card→detail | 9 |
| Polish + rendered QA catalog | 10 |
| Queue/History/Inbox one-shot left alone | 2 grep allow-list |
| No SwiftData / no new flag | Global Constraints |

**Placeholder scan:** no TBD / “implement later” / “similar to Task N” without the actual snippet.

**Type consistency:** `ArtworkSource.localFile/remote/placeholder`, `AlbumObjectRole.browse/play`, `MusicObjectMetrics.*`, `MusesMotion.*`, `ArtworkContinuityID.liveCover`, `HomeSection.id: String` for `retryingIDs`.
