### Task 12: PlayerBar 底部播放器栏

**Files:**
- Create: `Muses/Sources/Muses/Features/PlayerBar.swift`
- Modify: `Muses/Sources/Muses/Features/LibraryView.swift` (remove the PlayerBar stub — it moves to its own file; then the stub MARK section is gone entirely)

**Interfaces:**
- Consumes: `PlaybackService` (@Observable via `@Environment`), `PlayerState` (via `playback.state`), `ArtworkCache.default.path(forHash:)` (URL?), `BrandColors`.
- Produces: `PlayerBar` — 底部 76pt 固定栏:左侧封面+元数据 / 中间控制+进度 / 右侧音量+队列+全屏按钮。

**CRITICAL — stub removal:** Task 10/11 left a minimal `PlayerBar` stub at the bottom of `Muses/Sources/Muses/Features/LibraryView.swift` (in the `// MARK: - Stub (replaced by Task 12)` section). You MUST remove that stub before/after creating the real `PlayerBar.swift`, otherwise there will be a duplicate-definition compile error. After removal, the stub MARK section is gone entirely (LibraryView.swift ends after SettingsPlaceholderView).

**Verified API facts:**
- `PlaybackService` (@Observable @MainActor): `state` (PlayerState), `volume: Float`, `toggle()`, `next()`, `previous()`, `seek(to: Double)`, `setVolume(_ v: Float)`.
- `PlayerState` (@Observable @MainActor): `track: TrackSnapshot?`, `isPlaying: Bool`, `position: Double`, `duration: Double`, `error: PlayerError?`.
- `TrackSnapshot`: `title: String`, `artist: String`, `artworkHash: String?`, `artworkUrl: String?`.
- `ArtworkCache.default.path(forHash: String) -> URL?`; `NSImage(byReferencing: URL)`.
- `BrandColors` (RootView.swift): `background`, `surface`, `magenta`, `cyan`, `green`, `textPrimary`, `textSecondary`.
- RootView overlays `PlayerBar()` at the bottom (`.overlay(alignment: .bottom) { PlayerBar() }`). PlayerBar is environment-scoped — it reads `@Environment(PlaybackService.self)`. No constructor args.

- [ ] **Step 1: 移除 stub**

In `Muses/Sources/Muses/Features/LibraryView.swift`: remove the entire `// MARK: - Stub (replaced by Task 12)` section (the `struct PlayerBar` stub and its comment). LibraryView.swift should end after `SettingsPlaceholderView`.

- [ ] **Step 2: 实现 PlayerBar**

`Muses/Sources/Muses/Features/PlayerBar.swift`:
```swift
import SwiftUI
import AppKit

struct PlayerBar: View {
    @Environment(PlaybackService.self) private var playback
    @State private var seeking = false
    @State private var seekValue: Double = 0

    var body: some View {
        HStack(spacing: 16) {
            leadingBlock
            centerBlock
            trailingBlock
        }
        .padding(.horizontal, 16)
        .frame(height: 76)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.white.opacity(0.08)), alignment: .top)
    }

    private var leadingBlock: some View {
        HStack(spacing: 12) {
            artwork
                .frame(width: 56, height: 56)
                .cornerRadius(6)
            VStack(alignment: .leading, spacing: 2) {
                Text(playback.state.track?.title ?? "").font(.callout).lineLimit(1).foregroundStyle(.white)
                Text(playback.state.track?.artist ?? "").font(.caption)
                    .foregroundStyle(BrandColors.textSecondary).lineLimit(1)
            }
            .frame(width: 180, alignment: .leading)
        }
    }

    private var artwork: some View {
        Group {
            if let h = playback.state.track?.artworkHash,
               let p = ArtworkCache.default.path(forHash: h) {
                Image(nsImage: NSImage(byReferencing: p)).resizable().scaledToFill()
            } else {
                Rectangle().fill(BrandColors.surface)
            }
        }
        .clipped()
    }

    private var centerBlock: some View {
        VStack(spacing: 4) {
            HStack(spacing: 24) {
                Button { playback.previous() } label: { Image(systemName: "backward.fill") }
                    .foregroundStyle(.white)
                Button { playback.toggle() } label: {
                    Image(systemName: playback.state.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                }
                .foregroundStyle(BrandColors.magenta)
                Button { playback.next() } label: { Image(systemName: "forward.fill") }
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                Text(format(playback.state.position)).font(.caption2).foregroundStyle(BrandColors.textSecondary)
                Slider(value: Binding(
                    get: { playback.state.position },
                    set: { v in seeking = true; seekValue = v }),
                      in: 0...max(playback.state.duration, 1),
                    onEditingChanged: { end in
                        if end { playback.seek(to: seekValue); seeking = false }
                    })
                .tint(BrandColors.magenta)
                Text(format(playback.state.duration)).font(.caption2).foregroundStyle(BrandColors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var trailingBlock: some View {
        HStack(spacing: 16) {
            Slider(value: Binding(
                get: { Double(playback.volume) },
                set: { playback.setVolume(Float($0)) }), in: 0...1)
                .frame(width: 100).tint(BrandColors.cyan)
            Button { } label: { Image(systemName: "list.bullet") }.foregroundStyle(BrandColors.textSecondary)
            Button { } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .foregroundStyle(BrandColors.textSecondary)
        }
    }

    private func format(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}
```

**Notes on the plan's original code (no changes needed, but verify):**
- The seek Slider uses `onEditingChanged` — the user drags, `seeking=true` and `seekValue` track the drag; on release (`end == true`), `playback.seek(to: seekValue)` and `seeking=false`. This is the standard two-state seek pattern.
- The volume Slider calls `playback.setVolume` on every change (no debounce) — acceptable for Phase 1 (setVolume just clamps and sets player.volume).
- The queue (`list.bullet`) and fullscreen (`arrow.up.left.and.arrow.down.right`) buttons are no-ops for Phase 1 (empty action closures). Phase 2/3 wires them (queue drawer, Now Playing fullscreen).
- `.ultraThinMaterial` background gives the translucent TIDAL-like bar.

- [ ] **Step 3: 构建验证**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift build`
Expected: 编译通过。Watch for: duplicate `PlayerBar` definition if the stub wasn't removed.

- [ ] **Step 4: 运行验证 (optional, GUI)**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift run`
Expected: 底部出现 76pt PlayerBar;播放曲目后显示封面/标题/进度/控制,可拖动进度 seek,播放/暂停切换,音量调节。Skip if headless.

- [ ] **Step 5: 全量回归**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift test`
Expected: all 25 tests still pass (no regression).

- [ ] **Step 6: Commit**

Run:
```bash
cd /Users/xiaotwu/Code/xyz
git add -A
git commit -m "feat: PlayerBar (cover/progress/controls/volume, seek binding)"
```

---