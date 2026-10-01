import SwiftUI
import AppKit

/// A compact native transport surface sharing the main player's controls and semantics.
struct MenuBarPlayerView: View {
    @Environment(YouTubeImportService.self) private var importService: YouTubeImportService?
    @State private var presentationRow: CollectionTrackRow?
    @State private var songMetadata: YTDlpBridge.YTDlpPlaylistEntry?
    @Environment(PlaybackService.self) private var playback
    @Environment(AudioDeviceService.self) private var audioDevices: AudioDeviceService?
    var onOpenMain: () -> Void = {}
    var onQuit: () -> Void = {}
    @State private var volumePresented = false
    @State private var isSeeking = false
    @State private var seekPosition = 0.0

    private var track: TrackSnapshot? { playback.transportState.track }
    private var duration: Double { max(0, playback.transportState.duration) }
    private var position: Double { isSeeking ? seekPosition : playback.transportState.position }

    private var songInformation: SongDisplayInformation? {
        guard let current = track else { return nil }
        let row = presentationRow.flatMap { $0.snapshot.id == current.id ? $0 : nil }
            ?? CollectionTrackRow(snapshot: current, canonicalIndex: 0)
        return SongDisplayInformation(row: row, metadata: songMetadata)
    }

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
                    Text(songInformation?.title ?? tr("Not Playing", "未在播放"))
                        .font(MusesTypography.song(size: 14, emphasized: true, text: songInformation?.title ?? "")).lineLimit(2)
                    Text(songInformation?.artist ?? "Muses")
                        .font(MusesTypography.song(size: 12, text: songInformation?.artist ?? "")).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

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
                .font(MusesTypography.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                RepeatPlaybackButton(hit: 32, iconSize: 14)
                    .disabled(track == nil)
                Spacer(minLength: 0)
                ChromeIconButton(systemName: "backward.fill", help: tr("Previous", "上一首"),
                                 accessibility: tr("Previous", "上一首")) { playback.previous() }
                    .disabled(track == nil)
                Button { playback.toggle() } label: {
                    Image(systemName: playback.primaryAction.symbol)
                        .font(MusesTypography.system(size: 24, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.fullAreaPlain)
                .modifier(PlaybackCoreSurface()).help(playback.primaryAction.title)
                .disabled(track == nil)
                .accessibilityLabel(playback.primaryAction.title)
                ChromeIconButton(systemName: "forward.fill", help: tr("Next", "下一首"),
                                 accessibility: tr("Next", "下一首")) { playback.next() }
                    .disabled(track == nil)
                Spacer(minLength: 0)
                ChromeIconMenu(systemName: "ellipsis", title: tr("Player options", "播放器选项")) {
                    Button(tr("Open Muses", "打开 Muses"), action: onOpenMain)
                    Button(tr("Volume", "音量")) { volumePresented.toggle() }
                    Button(tr("Shuffle", "随机播放")) { playback.queue.toggleShuffle() }
                    if let id = track?.youTubeId, let url = URL(string: "https://youtu.be/\(id)") {
                        ShareLink(item: url)
                    }
                    Divider()
                    Button(tr("Quit Muses", "退出 Muses"), action: onQuit)
                }
            }
            .environment(\.groupedChromeActions, true)
            if volumePresented {
                LiquidGlassVolumeBar(width: 296, height: 60, scaleStyle: .dots)
                    .preferredColorScheme(.dark)
            }

            if let audioDevices, audioDevices.lastError != nil {
                Text(tr("Unable to switch audio output. Try again.", "无法切换音频输出，请重试。", zhHant: "無法切換音訊輸出，請重試。"))
                    .font(MusesTypography.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 332)
        .background(LinearGradient(colors: [BrandColors.accent.opacity(0.08), Color.white.opacity(0.025)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .foregroundStyle(BrandColors.textPrimary)
        .tint(BrandColors.accent)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: track?.id) {
            songMetadata = nil
            presentationRow = nil
            guard let current = track, let importService else { return }
            presentationRow = importService.songPresentationRow(for: current)
            let metadata = await importService.songMetadata(videoID: current.youTubeId)
            guard !Task.isCancelled, track?.id == current.id else { return }
            songMetadata = metadata
        }
        .onAppear { audioDevices?.refresh() }
        .onChange(of: track?.id) { _, _ in isSeeking = false }
    }

    private func formatTime(_ value: Double) -> String {
        let seconds = value.isFinite ? max(0, Int(value)) : 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
