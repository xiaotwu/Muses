### Task 5: NowPlayingView 主体(巨大封面模式)

**Files:**
- Create: `Muses/Sources/Muses/Features/NowPlaying/NowPlayingView.swift`
- Create: `Muses/Sources/Muses/Features/NowPlaying/CoverArtModeView.swift`
- Create: `Muses/Sources/Muses/Features/NowPlaying/LyricsPlaceholderView.swift`
- Modify: `Muses/Sources/Muses/Features/PlayerBar.swift`(封面点击触发)
- Modify: `Muses/Sources/Muses/App/RootView.swift`(全屏覆盖)

**Verified API facts:**
- `TrackSnapshot` fields: id, title, artist, albumTitle?, durationSeconds, filePath?, youTubeId?, artworkHash?, artworkUrl?, sampleRate?, bitDepth?, codec?, isLossless
- `PlayerState`: track?, isPlaying, position, duration, source, quality?(AudioQualityInfo: sampleRate/bitDepth/codec/isLossless), error?
- `PlaybackService`: toggle(), seek(to:), next(), previous(), setVolume(_:), state
- `ArtworkCache.default.path(forHash: String) -> URL?` → NSImage(byReferencing:)
- `AlbumArtworkExtractor.dominantColors(_ image: NSImage, count: Int = 3) -> [NSColor]`
- `BrandColors`: background, surface, magenta, cyan, green, textPrimary, textSecondary
- `SpectrumView` / `WaveformView`: drop-in, @Environment(PlaybackService.self), heights 120/60
- `@AppStorage(PrefKey.nowPlayingMode)` raw String → NowPlayingMode(rawValue:) ?? .cover
- `NowPlayingMode`: .cover / .vinyl (Task 4)
- macOS 14: `.fullScreenCover(isPresented:)` available. `onKeyPress(.space)` via `.onKeyPress` (macOS 14+). `@Namespace` for matchedGeometryEffect.

**Downstream contracts:**
- `NowPlayingView(isPresented:)` — RootView presents via fullScreenCover. Takes a Binding<Bool> for dismiss.
- `CoverArtModeView(artworkHash:)` — displays the 480×480 cover with shadow. Used by NowPlayingView in .cover mode. Task 6 adds VinylModeView for .vinyl mode.
- `LyricsPlaceholderView` — three-line placeholder, Phase 3 hooks LyricsService.

**Implementation plan:**
1. NowPlayingView: ZStack gradient background (recompute on track change), top toolbar (✕/NOW PLAYING/play-pause), center mode switch, bottom spectrum+waveform+meta+progress+lyrics. Gestures: space=toggle, horizontal drag=seek.
2. CoverArtModeView: 480×480 rounded cover, shadow 24.
3. LyricsPlaceholderView: 3-line placeholder.
4. PlayerBar: add onTapGesture to artwork → callback closure.
5. RootView: @State showNowPlaying, fullScreenCover presenting NowPlayingView.

---