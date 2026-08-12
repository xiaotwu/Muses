import SwiftUI

/// 播放设置: 交叉淡入淡出时长(无缝播放)。
struct PlaybackSettingsView: View {
    @AppStorage(PrefKey.crossfadeSeconds) private var crossfadeSeconds: Double = 0
    @AppStorage(PrefKey.replayGainEnabled) private var replayGainEnabled: Bool = false

    var body: some View {
        Section("播放") {
            // 交叉淡入淡出
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("交叉淡入淡出")
                        .foregroundStyle(BrandColors.textPrimary)
                    Spacer()
                    Text(crossfadeSeconds == 0 ? "关闭(纯无缝)" : String(format: "%.1f 秒", crossfadeSeconds))
                        .font(.callout)
                        .foregroundStyle(BrandColors.textSecondary)
                        .monospacedDigit()
                }

                Slider(value: $crossfadeSeconds, in: 0...12, step: 0.5)
                    .tint(BrandColors.cyan)

                Text("0 秒 = 纯无缝切换(无淡入淡出);> 0 秒 = 相邻曲目重叠交叉淡入淡出。仅本地文件生效。")
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
            }

            Divider().padding(.vertical, 4)

            // ReplayGain
            Toggle(isOn: $replayGainEnabled) {
                Text("ReplayGain 增益")
                    .foregroundStyle(BrandColors.textPrimary)
            }
            .tint(BrandColors.cyan)

            Text("启用后按文件内 ReplayGain 标签自动调整音量,使各曲目响度一致。无标签的曲目不受影响。")
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
        }
    }
}