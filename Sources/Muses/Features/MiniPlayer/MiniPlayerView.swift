import SwiftUI
import AppKit

/// Mini player (Final Spec §10.1 Feature 1).
///
/// Standalone `WindowGroup("MiniPlayer")` scene: cover + title/artist + previous/play/next +
/// progress + like + volume. Shares the same `PlaybackService` (no second engine).
/// Multi-display aware: window position/size persist via `setFrameAutosaveName("MusesMiniPlayer")`.
/// Always-on-top is toggleable. The `PrefKey.ffMiniPlayer` flag is checked by whichever entry
/// point opens it (menu / hotkey / tray).
struct MiniPlayerView: View {
    @Environment(PlaybackService.self) private var playback
    @Environment(LibraryService.self) private var library
    @AppStorage(PrefKey.theme) private var theme = "auto"
    @State private var alwaysOnTop = true
    @State private var isHovered = false

    private var progressFraction: CGFloat {
        guard playback.state.duration > 0 else { return 0 }
        return CGFloat(min(1.0, max(0.0, playback.state.position / playback.state.duration)))
    }

    var body: some View {
        ThemeApplier {
            let shape = Capsule()
            HStack(spacing: 12) {
                // Left: Circular Play/Pause button with circular progress ring (Figure 1)
                playWithProgressRing

                // Center: Track Title & Artist
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(artist)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(BrandColors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Right: Frosted circular Prev & Next buttons + Pin toggle (Figure 1)
                HStack(spacing: 6) {
                    circularFrostedButton("backward.fill", help: tr("Previous", "上一首")) {
                        playback.previous()
                    }

                    circularFrostedButton("forward.fill", help: tr("Next", "下一首")) {
                        playback.next()
                    }

                    Button {
                        alwaysOnTop.toggle()
                    } label: {
                        Image(systemName: alwaysOnTop ? "pin.fill" : "pin")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(alwaysOnTop ? BrandColors.magenta : BrandColors.textSecondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(tr("Keep on top", "常驻置顶"))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(width: 340, height: 60)
            .musesGlass(in: shape, role: .player)
            .overlay(
                shape.stroke(isHovered ? Color.white.opacity(0.28) : BrandColors.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            .onHover { isHovered = $0 }
        }
        .windowLevel(alwaysOnTop ? .floating : .normal)
        .background(WindowAccessor { win in
            win?.setFrameAutosaveName("MusesMiniPlayer")
        })
    }

    // MARK: - Subviews

    private var playWithProgressRing: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !playback.state.isPlaying)) { _ in
            Button {
                playback.toggle()
            } label: {
                ZStack {
                    // Background track ring
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 2.5)
                        .frame(width: 38, height: 38)

                    // Active progress ring (Figure 1)
                    Circle()
                        .trim(from: 0, to: progressFraction)
                        .stroke(
                            BrandColors.magenta,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 38, height: 38)

                    // Center Play/Pause button
                    Circle()
                        .fill(BrandColors.magenta)
                        .frame(width: 30, height: 30)

                    Image(systemName: playback.state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: playback.state.isPlaying ? 0 : 1)
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(playback.state.isPlaying ? tr("Pause", "暂停") : tr("Play", "播放"))
        }
    }

    private func circularFrostedButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 30, height: 30)
                Circle()
                    .stroke(Color.white.opacity(0.20), lineWidth: 0.75)
                    .frame(width: 30, height: 30)
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(BrandColors.textPrimary)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Helpers

    private var title: String { playback.state.track?.title ?? tr("Not Playing", "未在播放") }
    private var artist: String { playback.state.track?.artist ?? "Muses" }
}

/// SwiftUI window accessor: gets the underlying `NSWindow` so native properties like autosave/level can be set.
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
    /// Sets the hosting window's `NSWindow.level`.
    func windowLevel(_ level: NSWindow.Level) -> some View {
        background(WindowAccessor { win in win?.level = level })
    }
}