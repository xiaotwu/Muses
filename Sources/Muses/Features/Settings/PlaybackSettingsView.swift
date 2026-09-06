import SwiftUI

/// Playback settings: crossfade duration (gapless playback).
struct PlaybackSettingsView: View {
    @AppStorage(PrefKey.crossfadeSeconds) private var crossfadeSeconds: Double = 0
    @AppStorage(PrefKey.replayGainEnabled) private var replayGainEnabled: Bool = false
    @AppStorage(PrefKey.resumeAfterVideo) private var resumeAfterVideo: Bool = true

    var body: some View {
        Section(tr("Playback", "播放")) {
            // Crossfade
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(tr("Crossfade", "交叉淡入淡出"))
                        .foregroundStyle(BrandColors.textPrimary)
                    Spacer()
                    Text(crossfadeSeconds == 0 ? tr("Off", "关闭") : "\(String(format: "%.1f", crossfadeSeconds)) \(tr("sec", "秒"))")
                        .font(.callout)
                        .foregroundStyle(BrandColors.textSecondary)
                        .monospacedDigit()
                }

                Slider(value: $crossfadeSeconds, in: 0...12, step: 0.5)
                    .tint(BrandColors.magenta)
            }

            Divider().padding(.vertical, 4)

            // ReplayGain
            Toggle(isOn: $replayGainEnabled) {
                Text(tr("Sound Check (ReplayGain)", "音量平衡 (ReplayGain)"))
                    .foregroundStyle(BrandColors.textPrimary)
            }
            .tint(BrandColors.magenta)

            Divider().padding(.vertical, 4)

            Toggle(isOn: $resumeAfterVideo) {
                Text(tr("Resume music when video closes", "关闭视频后继续播放音乐"))
                    .foregroundStyle(BrandColors.textPrimary)
            }
            .tint(BrandColors.magenta)

            Divider().padding(.vertical, 4)

            // Hover preview
            Toggle(isOn: $hoverPreviewSound) {
                Text(tr("Play sound on hover preview", "悬停预览时播放声音"))
                    .foregroundStyle(BrandColors.textPrimary)
            }
            .tint(BrandColors.magenta)
        }
    }

    @AppStorage(PrefKey.hoverPreviewSound) private var hoverPreviewSound = false
}
