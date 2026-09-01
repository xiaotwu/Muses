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

