### Task 11: AlbumDetailView 封面主色渐变 + 曲目表

**Files:**
- Create: `Muses/Sources/Muses/Features/AlbumDetailView.swift`
- Modify: `Muses/Sources/Muses/Features/LibraryView.swift` (remove the AlbumDetailView stub — it moves to its own file)

**Interfaces:**
- Consumes: `Album` (@Model), `Track` (@Model), `PlaybackService` (@Observable via `@Environment`), `AlbumArtworkExtractor.dominantColors(_:count:)` (Task 9), `ArtworkCache.default.path(forHash:)` (URL?), `TrackSnapshot(from: Track)`, `BrandColors`.
- Produces: `AlbumDetailView(album: Album)` — gradient background derived from cover art dominant colors + large cover + album header (title/artist/Play button) + sorted track list; tapping a row plays the album from that track. Also produces `TrackRow` (reusable in SongsListView later if desired).

**CRITICAL — stub removal:** Task 10 added a minimal `AlbumDetailView` stub at the bottom of `Muses/Sources/Muses/Features/LibraryView.swift` (in the `// MARK: - Stubs` section). You MUST remove that stub before/after creating the real `AlbumDetailView.swift`, otherwise there will be a duplicate-definition compile error. Leave the `PlayerBar` stub (Task 12 replaces it). Update the stub MARK comment to reflect only PlayerBar remains.

**Verified API facts:**
- `Album` (@Model): `id: UUID`, `title: String`, `albumArtist: String`, `artworkHash: String?`, `tracks: [Track]`.
- `Track` (@Model): `id`, `title`, `artist`, `durationSeconds: Double`, `trackNo: Int?`, `discNo: Int?`, `isLossless: Bool`, `album: Album?`.
- `TrackSnapshot(from track: Track)` exists — convert each track to a snapshot for the playback context.
- `AlbumArtworkExtractor.dominantColors(_ image: NSImage, count: Int = 3) -> [NSColor]` (Task 9). Returns avg + shadow(0.4) + highlight(0.3) variants; empty for invalid images.
- `ArtworkCache.default.path(forHash: String) -> URL?`; `NSImage(byReferencing: URL)`; `NSImage(contentsOf: URL)` (loads file).
- `PlaybackService` API: `playTrack(_ track: TrackSnapshot, context: [TrackSnapshot], from: QueueSource)`. Use `.album` as the QueueSource.
- `BrandColors` (defined in RootView.swift): `background`, `surface`, `magenta`, `cyan`, `green`, `textPrimary`, `textSecondary`.
- `QueueSource` enum (defined in Domain/Enums.swift) has `.album` case (verify; if the case name differs, use the correct one — check `Enums.swift`).
- RootView shows `AlbumDetailView(album:)` when `selectedAlbum != nil`. There is no automatic back button in the stub-driven approach — add a back button in AlbumDetailView's toolbar to clear the selection. BUT: RootView owns `selectedAlbum` as `@State`, and AlbumDetailView is a child. To clear it, either (a) pass a `onClose: () -> Void` binding/closure into AlbumDetailView, or (b) use a `@Binding var selectedAlbum: Album?` passed from RootView. **Use option (b)**: change RootView's `if let album = selectedAlbum` block to pass the binding so AlbumDetailView can set it to nil. Specifically:
  ```swift
  if let album = selectedAlbum {
      AlbumDetailView(album: album, selection: $selectedAlbum)
  } else { ... }
  ```
  and in AlbumDetailView add `@Binding var selection: Album?` and a toolbar back button that sets `selection = nil`.

- [ ] **Step 0: Verify QueueSource case name**

Run: `grep -n "enum QueueSource" -A 6 Muses/Sources/Muses/Domain/Enums.swift`
Confirm the `.album` case exists (or whatever it's named). Use the actual case name.

- [ ] **Step 1: 移除 stub, 修改 RootView 传 binding**

In `Muses/Sources/Muses/Features/LibraryView.swift`: remove the `struct AlbumDetailView` from the `// MARK: - Stubs` section. Update the MARK comment to: `// MARK: - Stub (replaced by Task 12)` and keep only `PlayerBar`.

In `Muses/Sources/Muses/App/RootView.swift`: change the detail block to pass the selection binding:
```swift
detail: {
    if let album = selectedAlbum {
        AlbumDetailView(album: album, selection: $selectedAlbum)
    } else {
        switch section {
        case .home, .albums: LibraryView(selection: $section, selectedAlbum: $selectedAlbum)
        case .songs: SongsListView()
        case .liked: LikedView()
        case .settings: SettingsPlaceholderView()
        }
    }
}
```

- [ ] **Step 2: 实现 AlbumDetailView**

`Muses/Sources/Muses/Features/AlbumDetailView.swift`:
```swift
import SwiftUI
import AppKit

struct AlbumDetailView: View {
    let album: Album
    @Binding var selection: Album?
    @Environment(PlaybackService.self) private var playback
    @State private var gradient: [Color] = [BrandColors.background, BrandColors.surface]

    var body: some View {
        ZStack {
            LinearGradient(colors: gradient, startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    trackList
                }
                .padding(24)
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { selection = nil } label: { Image(systemName: "chevron.backward") }
            }
        }
        .onAppear { extractGradient() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            artwork
                .frame(width: 220, height: 220)
                .shadow(radius: 12)
            VStack(alignment: .leading, spacing: 8) {
                Text(album.title).font(.largeTitle).fontWeight(.bold).foregroundStyle(.white)
                Text(album.albumArtist).font(.title3).foregroundStyle(BrandColors.textSecondary)
                Button { playAll() } label: {
                    Label("Play", systemImage: "play.fill").padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColors.magenta)
            }
            Spacer()
        }
    }

    private var artwork: some View {
        Group {
            if let h = album.artworkHash, let p = ArtworkCache.default.path(forHash: h) {
                Image(nsImage: NSImage(byReferencing: p)).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 8).fill(BrandColors.surface)
                    .overlay(Image(systemName: "music.note").font(.largeTitle))
            }
        }
        .clipped().cornerRadius(8)
    }

    private var trackList: some View {
        VStack(spacing: 0) {
            ForEach(sortedTracks(), id: \.id) { track in
                TrackRow(track: track)
                    .onTapGesture { play(track) }
                    .padding(.vertical, 6)
            }
        }
    }

    private func sortedTracks() -> [Track] {
        album.tracks.sorted { (a, b) in
            (a.discNo ?? 0, a.trackNo ?? 0) < (b.discNo ?? 0, b.trackNo ?? 0)
        }
    }

    private func play(_ track: Track) {
        let ctx = sortedTracks().map { TrackSnapshot(from: $0) }
        guard let snap = ctx.first(where: { $0.id == track.id }) else { return }
        playback.playTrack(snap, context: ctx, from: .album)
    }

    private func playAll() {
        guard let first = sortedTracks().first else { return }
        play(first)
    }

    private func extractGradient() {
        guard let h = album.artworkHash, let p = ArtworkCache.default.path(forHash: h),
              let img = NSImage(contentsOf: p) else { return }
        let colors = AlbumArtworkExtractor.dominantColors(img, count: 3)
        gradient = colors.map { Color(nsColor: $0) } + [BrandColors.background]
    }
}

struct TrackRow: View {
    let track: Track
    var body: some View {
        HStack {
            Text("\(track.trackNo ?? 0)").foregroundStyle(BrandColors.textSecondary)
                .frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading) {
                Text(track.title).foregroundStyle(.white)
                Text(track.artist).font(.caption).foregroundStyle(BrandColors.textSecondary)
            }
            Spacer()
            if track.isLossless {
                Text("Hi-Res").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(BrandColors.green.opacity(0.2))
                    .foregroundStyle(BrandColors.green).cornerRadius(4)
            }
            Text(formatDuration(track.durationSeconds)).foregroundStyle(BrandColors.textSecondary)
        }
    }
    private func formatDuration(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}
```

**Notes on the plan's original code (fixes applied here):**
- Added a `@Binding var selection: Album?` and a toolbar back button to clear it (the plan's RootView has no nav stack, so the detail needs its own back affordance).
- The plan's `play(_:)` built snapshots then called `playback.playTrack(TrackSnapshot(from: track), ...)` — but `TrackSnapshot(from:)` needs a `Track`, and we already have `ctx` of snapshots. Fixed to find the matching snapshot by id (avoids re-snapshotting and ensures the played track's id matches the context's). This also ensures `queue.play` finds the track in the context by id (QueueService uses `firstIndex(where: { $0.id == track.id })`).
- `Color(nsColor:)` is the bridge from NSColor to SwiftUI Color.

- [ ] **Step 3: 构建验证**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift build`
Expected: 编译通过。Watch for: duplicate `AlbumDetailView` definition if the stub wasn't removed; `QueueSource.album` case name mismatch; `@Binding` wiring in RootView.

- [ ] **Step 4: 运行验证 (optional, GUI)**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift run`
Expected: 导入含音频的目录后,点击封面进入详情页,渐变背景从封面主色生成,曲目表可点播放,PlayerBar 出现当前曲目。Skip if headless.

- [ ] **Step 5: 全量回归**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift test`
Expected: all 25 tests still pass (no regression).

- [ ] **Step 6: Commit**

Run:
```bash
cd /Users/xiaotwu/Code/xyz
git add -A
git commit -m "feat: AlbumDetailView with cover-derived gradient + track list playback"
```

---