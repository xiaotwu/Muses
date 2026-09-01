import SwiftUI
import AppKit

/// Floating capsule player, matching live music.apple.com (not a full-width dock).
enum PlayerDockMetrics {
    static let height: CGFloat = AppleMusicTokens.capsuleHeight
    static let art: CGFloat = 40
    static let icon: CGFloat = 28
    static let play: CGFloat = 32
    /// Aligns the timeline with the capsule's straight top edge.
    static let progressHorizontalInset: CGFloat = height / 2
    static let progressTopInset: CGFloat = 0
    static let progressHeight: CGFloat = 3
}

struct PlayerBar: View {
    @Environment(PlaybackService.self) private var playback
    var lyricsActive: Bool = false
    var queueActive: Bool = false
    var onArtworkTap: () -> Void = {}
    var onLyricsTap: () -> Void = {}
    var onQueueTap: () -> Void = {}
    var onVideoTap: () -> Void = {}

    @State private var showVolume = false
    @FocusState private var artworkFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: AppleMusicTokens.capsuleCorner,
            style: .continuous
        )
        ZStack {
            HStack(spacing: 12) {
                PlaybackTransport()
                if playback.state.track == nil {
                    Spacer(minLength: 8)
                } else {
                    playingIdentity
                        .frame(maxWidth: .infinity)
                }
                trailing
            }
            if playback.state.track == nil {
                MusesMark(size: PlayerDockMetrics.art)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(tr("Not Playing", "未在播放"))
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: AppleMusicTokens.capsuleWidth)
        .frame(height: PlayerDockMetrics.height)
        .musesGlass(in: shape, role: .player)
        .overlay(alignment: .top) {
            progressTrack
                .padding(.horizontal, PlayerDockMetrics.progressHorizontalInset)
                .padding(.top, PlayerDockMetrics.progressTopInset)
        }
        .clipShape(shape)
        .overlay(
            RoundedRectangle(cornerRadius: AppleMusicTokens.capsuleCorner, style: .continuous)
                .stroke(BrandColors.textPrimary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .contextMenu {
            Button(tr("Lyrics", "歌词")) { onLyricsTap() }
                .disabled(playback.state.track == nil)
            Button(tr("Queue", "队列")) { onQueueTap() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .musesRestorePlayerArtworkFocus)) { _ in
            guard playback.state.track != nil else { return }
            artworkFocused = true
        }
    }

    private var progressTrack: some View {
        GeometryReader { geo in
            let fraction = playback.state.duration > 0
                ? max(0, min(1, playback.state.position / playback.state.duration)) : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(BrandColors.textPrimary.opacity(0.15))
                Capsule()
                    .fill(BrandColors.magenta)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: PlayerDockMetrics.progressHeight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var playingIdentity: some View {
        HStack(spacing: 10) {
            Button(action: onArtworkTap) {
                ArtworkView(source: ArtworkSource.resolve(for: playback.state.track),
                            cornerRadius: 6, glyphSize: 14,
                            targetSize: PlayerDockMetrics.art)
                    .scaleEffect(playback.state.isPlaying && !reduceMotion ? 1.04 : 1.0)
                    .shadow(color: .black.opacity(playback.state.isPlaying ? 0.35 : 0),
                            radius: playback.state.isPlaying ? 8 : 0)
                    .frame(width: PlayerDockMetrics.art, height: PlayerDockMetrics.art)
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .focused($artworkFocused)
            .help(tr("Open Now Playing", "打开正在播放"))
            .accessibilityLabel(tr(
                "Open Now Playing for \(playback.state.track?.title ?? "")",
                "打开 \(playback.state.track?.title ?? "") 的正在播放页面"
            ))
            .accessibilityHint(tr(
                "Shows the full Now Playing view",
                "显示完整的正在播放页面"
            ))

            VStack(alignment: .leading, spacing: 1) {
                Text(playback.state.track?.title ?? "")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(1)
                Text(playback.state.track?.artist ?? "")
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Text("\(format(playback.state.position))  /  \(format(playback.state.duration))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(BrandColors.textSecondary)
                .fixedSize()
        }
    }

    private var trailing: some View {
        HStack(spacing: 4) {
            dockButton("quote.bubble", selected: lyricsActive,
                       help: tr("Lyrics", "歌词"), action: onLyricsTap)
                .opacity(playback.state.track == nil ? 0.35 : 1)
                .disabled(playback.state.track == nil)
            dockButton("list.bullet", selected: queueActive,
                       help: tr("Queue", "队列"), action: onQueueTap)
            Button { showVolume.toggle() } label: {
                ChromeGlyph(systemName: volumeIcon, selected: showVolume,
                            size: 14, hit: PlayerDockMetrics.play)
            }
            .buttonStyle(.plain)
            .help(tr("Volume", "音量"))
            .accessibilityLabel(tr("Volume", "音量"))
            .accessibilityValue("\(Int((playback.volume * 100).rounded()))%")
            .popover(isPresented: $showVolume, arrowEdge: .top) {
                Slider(value: Binding(
                    get: { Double(playback.volume) },
                    set: { playback.setVolume(Float($0)) }), in: 0...1)
                    .frame(width: 140)
                    .padding(12)
                    .tint(BrandColors.magenta)
            }
            youtubeButton
        }
    }

    private var youtubeButton: some View {
        Button(action: onVideoTap) {
            YouTubeMark(size: 13)
                .frame(width: PlayerDockMetrics.icon, height: PlayerDockMetrics.icon)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("Watch YouTube video", "观看 YouTube 视频"))
        .accessibilityLabel(tr("Watch YouTube video", "观看 YouTube 视频"))
        .opacity(playback.state.track?.youTubeId == nil ? 0.35 : 1)
        .disabled(playback.state.track?.youTubeId == nil)
    }

    private var volumeIcon: String {
        let v = playback.volume
        if v <= 0.001 { return "speaker.slash.fill" }
        if v < 0.33 { return "speaker.fill" }
        if v < 0.66 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    private func dockButton(_ system: String, selected: Bool = false,
                            help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ChromeGlyph(systemName: system, selected: selected, size: 13, hit: PlayerDockMetrics.icon)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(selected ? tr("On", "开启") : tr("Off", "关闭"))
    }

    private func format(_ s: Double) -> String {
        let t = max(0, Int(s.rounded()))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Shuffle / previous / filled play / next / repeat. Shared by the dock and Now Playing.
struct PlaybackTransport: View {
    var playHit: CGFloat = PlayerDockMetrics.play
    var iconHit: CGFloat = PlayerDockMetrics.icon
    var iconSize: CGFloat = 13

    @Environment(PlaybackService.self) private var playback

    var body: some View {
        HStack(spacing: 4) {
            transportButton("shuffle",
                            selected: playback.queue.shuffle,
                            help: tr("Shuffle", "随机")) {
                playback.queue.toggleShuffle()
            }
            transportButton("backward.fill", help: tr("Previous", "上一首")) {
                playback.previous()
            }
            Button { playback.toggle() } label: {
                ZStack {
                    Circle().fill(BrandColors.textPrimary)
                    Image(systemName: playback.state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BrandColors.background)
                        .offset(x: playback.state.isPlaying ? 0 : 1)
                }
                .frame(width: playHit, height: playHit)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(playback.state.isPlaying ? tr("Pause", "暂停") : tr("Play", "播放"))
            .accessibilityLabel(playback.state.isPlaying ? tr("Pause", "暂停") : tr("Play", "播放"))
            transportButton("forward.fill", help: tr("Next", "下一首")) {
                playback.next()
            }
            transportButton(repeatIcon,
                            selected: playback.queue.repeatMode != .off,
                            help: repeatHelp) {
                playback.queue.setRepeat(playback.queue.repeatMode.next)
            }
        }
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

    private func transportButton(_ system: String, selected: Bool = false,
                                 help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ChromeGlyph(systemName: system, selected: selected, size: iconSize, hit: iconHit)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(selected ? tr("On", "开启") : tr("Off", "关闭"))
    }
}

enum PlayerCapsuleMetrics {
    static let width: CGFloat = AppleMusicTokens.capsuleWidth
    static let height: CGFloat = PlayerDockMetrics.height
    static let art: CGFloat = PlayerDockMetrics.art
    static let icon: CGFloat = PlayerDockMetrics.icon
    static let play: CGFloat = PlayerDockMetrics.play
}

extension Notification.Name {
    /// Posted after Now Playing closes so keyboard focus returns to the sole
    /// PlayerBar entry point for reopening it.
    static let musesRestorePlayerArtworkFocus = Notification.Name(
        "muses.restorePlayerArtworkFocus"
    )
}
