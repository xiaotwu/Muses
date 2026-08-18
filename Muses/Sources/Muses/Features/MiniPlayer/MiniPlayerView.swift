import SwiftUI
import AppKit

/// 迷你播放器(Final Spec §10.1 Feature 1 — Mini Player)。
///
/// 独立 `WindowGroup("MiniPlayer")` 场景:封面 + 标题/艺术家 + 上一首/播放/下一首 +
/// 进度 + 收藏 + 音量。共享同一 `PlaybackService`(无第二引擎)。多显示器感知:
/// 窗口位置/尺寸通过 `setFrameAutosaveName("MusesMiniPlayer")` 持久化。
/// 常驻置顶可切换。功能开关 `PrefKey.ffMiniPlayer` 由打开入口(菜单/热键/托盘)判定。
struct MiniPlayerView: View {
    @Environment(PlaybackService.self) private var playback
    @Environment(LibraryService.self) private var library
    @AppStorage(PrefKey.theme) private var theme = "auto"
    @State private var alwaysOnTop = false

    var body: some View {
        ThemeApplier {
            VStack(spacing: 14) {
                ArtworkView(source: ArtworkSource.resolve(for: playback.state.track),
                             cornerRadius: 10, glyphSize: 48)
                    .frame(width: 180, height: 180)

                Text(title)
                    .font(.headline).lineLimit(1)
                    .foregroundStyle(BrandColors.textPrimary)
                Text(artist)
                    .font(.subheadline).lineLimit(1)
                    .foregroundStyle(BrandColors.textSecondary)

                progressView
                controls
                volumeRow
            }
            .padding(18)
            .frame(width: 240)
            .background(.regularMaterial)
            .overlay(alignment: .topTrailing) { topRightControls }
        }
        .windowLevel(alwaysOnTop ? .floating : .normal)
        .background(WindowAccessor { win in
            win?.setFrameAutosaveName("MusesMiniPlayer")
        })
    }

    // MARK: - 子视图

    private var progressView: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !playback.state.isPlaying)) { ctx in
            let pos = playback.state.position
            let dur = max(playback.state.duration, 0.001)
            ProgressView(value: min(pos / dur, 1.0))
                .tint(BrandColors.magenta)
        }
    }

    private var controls: some View {
        HStack(spacing: 22) {
            Button { playback.previous() } label: {
                Image(systemName: "backward.fill")
            }.buttonStyle(.borderless).help(tr("Previous", "上一首"))

            Button { playback.toggle() } label: {
                Image(systemName: playback.state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }.buttonStyle(.borderless).help(tr("Play / Pause", "播放/暂停"))

            Button { playback.next() } label: {
                Image(systemName: "forward.fill")
            }.buttonStyle(.borderless).help(tr("Next", "下一首"))

            Button { toggleLike() } label: {
                Image(systemName: isLiked ? "heart.fill" : "heart")
            }.buttonStyle(.borderless).help(tr("Like", "收藏"))
        }
        .font(.title3)
        .foregroundStyle(BrandColors.textPrimary)
    }

    private var volumeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill").foregroundStyle(BrandColors.textSecondary)
            Slider(value: Binding(get: { Double(playback.volume) },
                                    set: { playback.setVolume(Float($0)) }), in: 0...1)
                .tint(BrandColors.magenta)
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(BrandColors.textSecondary)
        }
        .font(.caption)
    }

    private var topRightControls: some View {
        Button { alwaysOnTop.toggle() } label: {
            Image(systemName: alwaysOnTop ? "pin.fill" : "pin")
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
        }
        .buttonStyle(.borderless)
        .padding(8)
        .help(tr("Keep on top", "常驻置顶"))
    }

    // MARK: - helpers

    private var title: String { playback.state.track?.title ?? tr("Not Playing", "未播放") }
    private var artist: String { playback.state.track?.artist ?? "—" }
    private var isLiked: Bool {
        guard let id = playback.state.track?.id, let t = library.track(by: id) else { return false }
        return t.liked
    }
    private func toggleLike() {
        guard let id = playback.state.track?.id else { return }
        library.toggleLike(id: id)
    }
}

/// SwiftUI 窗口访问器:拿到底层 `NSWindow` 以设置 autosave/level 等原生属性。
struct WindowAccessor: View {
    let onWindow: (NSWindow?) -> Void
    var body: some View {
        NSViewRepresentableAnchor(onWindow: onWindow)
    }
}

private struct NSViewRepresentableAnchor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onWindow(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}

extension View {
    /// 设置承载窗口的 `NSWindow.level`。
    func windowLevel(_ level: NSWindow.Level) -> some View {
        background(WindowAccessor { win in win?.level = level })
    }
}