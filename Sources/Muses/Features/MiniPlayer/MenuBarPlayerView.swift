import SwiftUI
import AppKit

/// A compact native transport surface sharing the main player's controls and semantics.
struct MenuBarPlayerView: View {
    @Environment(PlaybackService.self) private var playback
    @Environment(AudioDeviceService.self) private var audioDevices: AudioDeviceService?
    var onOpenMain: () -> Void = {}
    var onQuit: () -> Void = {}
    @State private var isSeeking = false
    @State private var seekPosition = 0.0

    private var track: TrackSnapshot? { playback.transportState.track }
    private var duration: Double { max(0, playback.transportState.duration) }
    private var position: Double { isSeeking ? seekPosition : playback.transportState.position }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                if let track {
                    ArtworkView(source: ArtworkSource.resolve(for: track), cornerRadius: 8,
                                glyphSize: 24, targetSize: 72)
                        .frame(width: 56, height: 56)
                } else {
                    MusesMark(size: 44)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(track?.title ?? tr("Not Playing", "未在播放"))
                        .font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    Text(track?.artist ?? "Muses")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 12) {
                    ChromeIconButton(systemName: "power", help: tr("Quit Muses", "退出 Muses"), accessibility: tr("Quit Muses", "退出 Muses"), action: onQuit)
                    ChromeIconButton(systemName: "arrow.up.forward.app", help: tr("Open Muses", "打开 Muses"), accessibility: tr("Open Muses", "打开 Muses"), action: onOpenMain)
                }

            }

            VStack(spacing: 2) {
                Slider(value: Binding(get: { min(duration, max(0, position)) }, set: {
                    seekPosition = $0
                    if !isSeeking { playback.seek(to: $0) }
                }),
                       in: 0...max(1, duration), onEditingChanged: { editing in
                    if editing { seekPosition = playback.transportState.position }
                    else { playback.seek(to: seekPosition) }
                    isSeeking = editing
                })
                .focusEffectDisabled()
                .disabled(track == nil || duration <= 0)
                .accessibilityLabel(tr("Playback position", "播放位置", zhHant: "播放位置"))
                HStack {
                    Text(formatTime(position))
                    Spacer()
                    Text("−" + formatTime(max(0, duration - position)))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                ChromeIconButton(systemName: playback.queue.repeatMode == .one ? "repeat.1" : "repeat",
                                 help: tr("Repeat", "循环"), accessibility: tr("Repeat", "循环")) {
                    playback.queue.setRepeat(playback.queue.repeatMode.next)
                }
                .foregroundStyle(playback.queue.repeatMode == .off ? BrandColors.textSecondary : BrandColors.accent)
                Spacer(minLength: 0)
                ChromeIconButton(systemName: "backward.fill", help: tr("Previous", "上一首"),
                                 accessibility: tr("Previous", "上一首")) { playback.previous() }
                Button { playback.toggle() } label: {
                    Image(systemName: playback.primaryAction.symbol)
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain).help(playback.primaryAction.title)
                .accessibilityLabel(playback.primaryAction.title)
                ChromeIconButton(systemName: "forward.fill", help: tr("Next", "下一首"),
                                 accessibility: tr("Next", "下一首")) { playback.next() }
                Spacer(minLength: 0)
                ChromeIconButton(systemName: "shuffle", help: tr("Shuffle", "随机播放"),
                                 accessibility: tr("Shuffle", "随机播放")) { playback.queue.toggleShuffle() }
                    .foregroundStyle(playback.queue.shuffle ? BrandColors.accent : BrandColors.textSecondary)
            }
            .disabled(track == nil)

            LiquidGlassVolumeBar(width: 296, height: 40)
            if let audioDevices, audioDevices.lastError != nil {
                Text(tr("Unable to switch audio output. Try again.", "无法切换音频输出，请重试。", zhHant: "無法切換音訊輸出，請重試。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 332)
        .foregroundStyle(BrandColors.textPrimary)
        .tint(BrandColors.accent)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { audioDevices?.refresh() }
        .onChange(of: track?.id) { _, _ in isSeeking = false }
    }

    private func formatTime(_ value: Double) -> String {
        let seconds = value.isFinite ? max(0, Int(value)) : 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
