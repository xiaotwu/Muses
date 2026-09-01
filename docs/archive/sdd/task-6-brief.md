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

