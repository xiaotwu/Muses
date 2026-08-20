import SwiftUI
import AppKit

/// Floating capsule player, matching live music.apple.com (not a full-width dock).
enum PlayerDockMetrics {
    static let height: CGFloat = AppleMusicTokens.capsuleHeight
    static let art: CGFloat = 40
    static let icon: CGFloat = 28
    static let play: CGFloat = 32
}

struct PlayerBar: View {
    @Environment(PlaybackService.self) private var playback
    var showNowPlaying: Bool = false
    var skipArtworkMorph: Bool = false
    var lyricsActive: Bool = false
    var queueActive: Bool = false
    var onArtworkTap: () -> Void = {}
    var onLyricsTap: () -> Void = {}
    var onQueueTap: () -> Void = {}
    var onVideoTap: () -> Void = {}

    @State private var showVolume = false
    @State private var seeking = false
    @State private var seekValue: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            identity.frame(width: 180, alignment: .leading)
            center.frame(maxWidth: .infinity)
            trailing
        }
        .padding(.horizontal, 14)
        .frame(width: AppleMusicTokens.capsuleWidth, height: PlayerDockMetrics.height)
        .background {
            DockBackground()
        }
        .clipShape(RoundedRectangle(cornerRadius: AppleMusicTokens.capsuleCorner, style: .continuous))
        .overlay(alignment: .top) {
            GeometryReader { geo in
                let frac = playback.state.duration > 0
                    ? max(0, min(1, playback.state.position / playback.state.duration)) : 0
                Rectangle()
                    .fill(BrandColors.magenta)
                    .frame(width: geo.size.width * frac, height: 2)
            }
            .frame(height: 2)
            .clipShape(Capsule())
        }
        .overlay(
            RoundedRectangle(cornerRadius: AppleMusicTokens.capsuleCorner, style: .continuous)
                .stroke(BrandColors.textPrimary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .focusEffectDisabled()
        .contextMenu {
            Button(tr("Open Now Playing", "打开正在播放")) { onArtworkTap() }
            Button(tr("Lyrics", "歌词")) { onLyricsTap() }
            Button(tr("Queue", "队列")) { onQueueTap() }
        }
    }

    private var identity: some View {
        Button(action: {
            guard playback.state.track != nil else { return }
            onArtworkTap()
        }) {
            HStack(spacing: 10) {
                ArtworkView(source: ArtworkSource.resolve(for: playback.state.track),
                            cornerRadius: 6, glyphSize: 14,
                            targetSize: PlayerDockMetrics.art)
                    .scaleEffect(playback.state.isPlaying && !reduceMotion ? 1.04 : 1.0)
                    .shadow(color: .black.opacity(playback.state.isPlaying ? 0.35 : 0),
                            radius: playback.state.isPlaying ? 8 : 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playback.state.track?.title ?? tr("Not Playing", "未在播放"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BrandColors.textPrimary)
                        .lineLimit(1)
                    Text(identitySubtitle)
                        .font(.caption)
                        .foregroundStyle(BrandColors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .help(tr("Now Playing", "正在播放"))
        .accessibilityLabel(playback.state.track.map { "\($0.title) — \($0.artist)" }
                            ?? tr("Not Playing", "未在播放"))
    }

    private var identitySubtitle: String {
        guard let track = playback.state.track else { return " " }
        if let album = track.albumTitle, !album.isEmpty {
            return "\(track.artist) — \(album)"
        }
        return track.artist
    }

    private var center: some View {
        HStack(spacing: 8) {
            dockButton("shuffle", selected: playback.queue.shuffle,
                       help: tr("Shuffle", "随机")) {
                playback.queue.toggleShuffle()
            }
            dockButton("backward.fill", help: tr("Previous", "上一首")) {
                playback.previous()
            }
            Button { playback.toggle() } label: {
                ChromeGlyph(
                    systemName: playback.state.isPlaying ? "pause.fill" : "play.fill",
                    selected: false,
                    size: 16,
                    hit: PlayerDockMetrics.play
                )
            }
            .buttonStyle(.plain)
            .help(playback.state.isPlaying ? tr("Pause", "暂停") : tr("Play", "播放"))
            .accessibilityLabel(playback.state.isPlaying ? tr("Pause", "暂停") : tr("Play", "播放"))
            dockButton("forward.fill", help: tr("Next", "下一首")) {
                playback.next()
            }
            dockButton(repeatIcon, selected: playback.queue.repeatMode != .off,
                       help: repeatHelp) {
                playback.queue.setRepeat(playback.queue.repeatMode.next)
            }
        }
    }

    private var scrubber: some View {
        HStack(spacing: 8) {
            Text(format(playback.state.position))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(BrandColors.textSecondary)
                .frame(width: 40, alignment: .trailing)
            Slider(value: Binding(
                get: { seeking ? seekValue : playback.state.position },
                set: { v in seeking = true; seekValue = v }),
                in: 0...max(playback.state.duration, 1),
                onEditingChanged: { editing in
                    if !editing { playback.seek(to: seekValue); seeking = false }
                }
            )
            .tint(BrandColors.magenta)
            .blocksWindowDrag()
            Text("−" + format(max(0, playback.state.duration - playback.state.position)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(BrandColors.textSecondary)
                .frame(width: 44, alignment: .leading)
        }
        .frame(maxWidth: 420)
    }

    private var trailing: some View {
        HStack(spacing: 4) {
            dockButton("quote.bubble", selected: lyricsActive,
                       help: tr("Lyrics", "歌词"), action: onLyricsTap)
            dockButton("list.bullet", selected: queueActive,
                       help: tr("Queue", "队列"), action: onQueueTap)
            Button(action: onVideoTap) {
                YouTubeMark(size: 14)
                    .frame(width: PlayerDockMetrics.play, height: PlayerDockMetrics.play)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(playback.state.track?.youTubeId == nil ? 0.35 : 1)
            .disabled(playback.state.track?.youTubeId == nil)
            .help(tr("Play YouTube video", "播放 YouTube 视频"))
            Button { showVolume.toggle() } label: {
                ChromeGlyph(systemName: volumeIcon, size: 14, hit: PlayerDockMetrics.play)
            }
            .buttonStyle(.plain)
            .help(tr("Volume", "音量"))
            .popover(isPresented: $showVolume, arrowEdge: .top) {
                Slider(value: Binding(
                    get: { Double(playback.volume) },
                    set: { playback.setVolume(Float($0)) }), in: 0...1)
                    .frame(width: 140)
                    .padding(12)
                    .tint(BrandColors.magenta)
            }
        }
    }

    private var volumeIcon: String {
        let v = playback.volume
        if v <= 0.001 { return "speaker.slash.fill" }
        if v < 0.33 { return "speaker.fill" }
        if v < 0.66 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    private var repeatIcon: String {
        playback.queue.repeatMode == .one ? "repeat.1" : "repeat"
    }

    private var repeatHelp: String {
        switch playback.queue.repeatMode {
        case .off: tr("Repeat: Off", "循环:关")
        case .one: tr("Repeat: One", "循环:单曲")
        case .all: tr("Repeat: Playlist", "循环:歌单")
        }
    }

    private func dockButton(_ system: String, selected: Bool = false,
                            help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ChromeGlyph(systemName: system, selected: selected, size: 13, hit: PlayerDockMetrics.icon)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func format(_ s: Double) -> String {
        let t = max(0, Int(s.rounded()))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Capsule fill: system material, opaque when Reduce Transparency is on.
private struct DockBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            BrandColors.surface
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }
}

enum PlayerCapsuleMetrics {
    static let width: CGFloat = 700
    static let height: CGFloat = PlayerDockMetrics.height
    static let art: CGFloat = PlayerDockMetrics.art
    static let icon: CGFloat = PlayerDockMetrics.icon
    static let play: CGFloat = PlayerDockMetrics.play
}
