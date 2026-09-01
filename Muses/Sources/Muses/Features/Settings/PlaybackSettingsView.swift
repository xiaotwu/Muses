import SwiftUI

/// 播放设置: 交叉淡入淡出时长(无缝播放)。
struct PlaybackSettingsView: View {
    @AppStorage(PrefKey.crossfadeSeconds) private var crossfadeSeconds: Double = 0
    @AppStorage(PrefKey.replayGainEnabled) private var replayGainEnabled: Bool = false
    @AppStorage(PrefKey.resumeAfterVideo) private var resumeAfterVideo: Bool = true

    var body: some View {
        Section(tr("Playback", "播放")) {
            // 交叉淡入淡出
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(tr("Crossfade", "交叉淡入淡出"))
                        .foregroundStyle(BrandColors.textPrimary)
                    Spacer()
                    Text(crossfadeSeconds == 0 ? tr("Off (gapless)", "关闭(纯无缝)") : "\(String(format: "%.1f", crossfadeSeconds)) \(tr("sec", "秒"))")
                        .font(.callout)
                        .foregroundStyle(BrandColors.textSecondary)
                        .monospacedDigit()
                }

                Slider(value: $crossfadeSeconds, in: 0...12, step: 0.5)
                    .tint(BrandColors.magenta)

                Text(tr("0 sec keeps gapless playback. Crossfade is applied when adjacent YouTube tracks are available in the stream cache.",
                        "0 秒保持无缝播放；相邻 YouTube 曲目已进入流缓存时可应用交叉淡入淡出。"))
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
            }

            Divider().padding(.vertical, 4)

            // ReplayGain
            Toggle(isOn: $replayGainEnabled) {
                Text(tr("ReplayGain", "ReplayGain 增益"))
                    .foregroundStyle(BrandColors.textPrimary)
            }
            .tint(BrandColors.magenta)

            Text(tr("When available in saved metadata, ReplayGain keeps loudness consistent across tracks. Tracks without a value are unchanged.",
                    "已保存的元数据包含 ReplayGain 时，会自动统一曲目响度；没有该值的曲目不受影响。"))
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)

            Divider().padding(.vertical, 4)

            Toggle(isOn: $resumeAfterVideo) {
                Text(tr("Resume music when video closes", "视频关闭后继续播放当前音乐队列"))
                    .foregroundStyle(BrandColors.textPrimary)
            }
            .tint(BrandColors.magenta)

            Text(tr("Opening a YouTube video always pauses music. When this is on, closing the video resumes the current queue. When off, music stays paused.", "打开 YouTube 视频总会暂停音乐。开启后,关闭视频会继续当前队列;关闭后则保持暂停。"))
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)

            Divider().padding(.vertical, 4)

            // 悬停预览:视觉交互,归播放设置;原YouTube页已精简。
            Toggle(isOn: $hoverPreviewSound) {
                Text(tr("Play sound on hover preview", "悬停预览时播放声音"))
                    .foregroundStyle(BrandColors.textPrimary)
            }
            .tint(BrandColors.magenta)

            Text(tr("Off by default. Covers still enlarge on hover.",
                    "默认关闭。悬停仍会放大封面。"))
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
        }
    }

    @AppStorage(PrefKey.hoverPreviewSound) private var hoverPreviewSound = false
}
