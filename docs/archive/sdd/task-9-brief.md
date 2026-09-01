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

