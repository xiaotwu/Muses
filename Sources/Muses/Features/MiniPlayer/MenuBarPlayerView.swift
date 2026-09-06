import SwiftUI
import AppKit

/// Menu Bar floating player card, faithfully matching Figure 2:
/// - Top row: Square artwork with smooth continuous corners, bold Title, and Artist
/// - Middle row: Monospace timestamps (elapsed and remaining) + white scrubber slider
/// - Bottom row: Loop/repeat, Previous, Play/Pause, Next, and Output/AirPlay controls
struct MenuBarPlayerView: View {
    @Environment(PlaybackService.self) private var playback
    @Environment(AudioDeviceService.self) private var audioDevices: AudioDeviceService?
    var onOpenMain: () -> Void = {}
    var onQuit: () -> Void = {}

    @State private var isDraggingScrubber = false
    @State private var dragScrubRatio: Double = 0
    @State private var isHovered = false

    private var track: TrackSnapshot? {
        playback.state.track
    }

    private var title: String {
        track?.title ?? tr("Not Playing", "未在播放")
    }

    private var artist: String {
        track?.artist ?? "Muses"
    }

    private var duration: Double {
        playback.state.duration
    }

    private var position: Double {
        playback.state.position
    }

    private var currentFraction: Double {
        if isDraggingScrubber { return dragScrubRatio }
        guard duration > 0 else { return 0 }
        return max(0, min(1, position / duration))
    }

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: 20, style: .continuous)

        VStack(spacing: 14) {
            // MARK: - Top Section: Artwork + Title/Artist + Quick Actions
            HStack(spacing: 12) {
                // Square Artwork (Fig 2)
                ArtworkView(
                    source: ArtworkSource.resolve(for: track),
                    cornerRadius: 14,
                    glyphSize: 28,
                    targetSize: 64,
                    presentation: .fill
                )
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 3)

                // Title & Artist
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(artist)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Quick open main window / quit buttons
                VStack(spacing: 6) {
                    Button(action: onOpenMain) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(tr("Open Muses", "打开 Muses"))

                    Button(action: onQuit) {
                        Image(systemName: "power")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(tr("Quit Muses", "退出 Muses"))
                }
            }

            // MARK: - Middle Section: Draggable Timeline Scrubber (Fig 2)
            VStack(spacing: 5) {
                // Timestamps: Elapsed and Remaining
                HStack {
                    Text(formatTime(isDraggingScrubber ? dragScrubRatio * duration : position))
                    Spacer()
                    Text("−" + formatTime(max(0, duration - (isDraggingScrubber ? dragScrubRatio * duration : position))))
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))

                // Custom Scrubber Slider with round white knob
                GeometryReader { geo in
                    let trackWidth = max(10, geo.size.width)
                    let knobDiameter: CGFloat = 12
                    let travel = max(1, trackWidth - knobDiameter)
                    let knobX = knobDiameter / 2 + CGFloat(currentFraction) * travel

                    ZStack(alignment: .leading) {
                        // Background track
                        Capsule()
                            .fill(Color.white.opacity(0.24))
                            .frame(height: 3.5)

                        // Filled active track
                        Capsule()
                            .fill(Color.white)
                            .frame(width: min(trackWidth, knobX), height: 3.5)

                        // Circular white knob (Fig 2)
                        Circle()
                            .fill(Color.white)
                            .frame(width: knobDiameter, height: knobDiameter)
                            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                            .position(x: knobX, y: geo.size.height / 2)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard duration > 0 else { return }
                                isDraggingScrubber = true
                                let clampedX = min(travel, max(0, value.location.x - knobDiameter / 2))
                                dragScrubRatio = Double(clampedX / travel)
                            }
                            .onEnded { _ in
                                if duration > 0 {
                                    playback.seek(to: dragScrubRatio * duration)
                                }
                                isDraggingScrubber = false
                            }
                    )
                }
                .frame(height: 18)
            }

            // MARK: - Bottom Section: Transport & Secondary Controls (Fig 2)
            HStack(spacing: 0) {
                // Left: Loop / Repeat button
                Button {
                    playback.queue.setRepeat(playback.queue.repeatMode.next)
                } label: {
                    Image(systemName: repeatIcon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(playback.queue.repeatMode != .off ? BrandColors.magenta : .white.opacity(0.8))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .help(tr("Repeat", "循环"))

                Spacer()

                // Center: Prev, Play/Pause, Next
                HStack(spacing: 18) {
                    Button { playback.previous() } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .help(tr("Previous", "上一首"))

                    Button { playback.toggle() } label: {
                        Image(systemName: playback.state.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .help(playback.state.isPlaying ? tr("Pause", "暂停") : tr("Play", "播放"))

                    Button { playback.next() } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .help(tr("Next", "下一首"))
                }

                Spacer()

                // Right: Output / AirPlay menu
                Menu {
                    if let devices = audioDevices?.devices, !devices.isEmpty {
                        ForEach(devices) { device in
                            Button {
                                _ = audioDevices?.setDefault(device.id)
                            } label: {
                                Label {
                                    Text(device.name)
                                } icon: {
                                    Image(systemName: device.id == audioDevices?.defaultDeviceID
                                          ? "checkmark"
                                          : "speaker.wave.2")
                                }
                            }
                        }
                    } else {
                        Text(tr("Default Audio Output", "默认音频输出"))
                    }
                } label: {
                    Image(systemName: "airplayaudio")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 32, height: 32)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help(tr("Audio Output", "音频输出"))
            }
        }
        .padding(16)
        .frame(width: 310)
        .background(
            ZStack {
                // Subtle ambient backdrop tint
                Color.black.opacity(0.65)
                LinearGradient(
                    colors: [
                        Color.blue.opacity(0.25),
                        Color.cyan.opacity(0.15),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
        .clipShape(cardShape)
        .overlay(
            cardShape.stroke(
                isHovered ? Color.white.opacity(0.35) : Color.white.opacity(0.18),
                lineWidth: 1
            )
        )
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .onHover { isHovered = $0 }
    }

    private var repeatIcon: String {
        switch playback.queue.repeatMode {
        case .off: return "repeat"
        case .one: return "repeat.1"
        case .all: return "repeat"
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let val = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", val / 60, val % 60)
    }
}
