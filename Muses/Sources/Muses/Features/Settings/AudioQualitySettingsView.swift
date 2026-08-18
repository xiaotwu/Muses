import SwiftUI

/// 音质设置: 本地音质 + YouTube 音质, 分别独立存储。
struct AudioQualitySettingsView: View {
    @AppStorage(PrefKey.localAudioQuality) private var localQuality: String = "native"
    @AppStorage(PrefKey.ytAudioQuality) private var ytQuality: String = "bestaudio"
    @AppStorage(PrefKey.ffAudioNerd) private var audioNerd = false

    var body: some View {
        Section(tr("Local Audio Quality", "本地音质")) {
            Picker(tr("Local Audio Quality", "本地音质"), selection: $localQuality) {
                Text(tr("Native", "原始 (Native)")).tag("native")
                Text(tr("Exclusive Mode", "独占模式 (Exclusive)")).tag("exclusive")
            }
            .pickerStyle(.radioGroup)
            Text(tr("Exclusive mode uses CoreAudio HAL for bit-perfect output.",
                    "独占模式使用 CoreAudio HAL 实现位完美输出。"))
                .font(.caption).foregroundStyle(BrandColors.textSecondary)
        }

        Section(tr("YouTube Music Audio Quality", "YouTube Music 音质")) {
            Picker(tr("YouTube Audio Quality", "YouTube 音质"), selection: $ytQuality) {
                Text(tr("Best (bestaudio)", "最高 (bestaudio)")).tag("bestaudio")
                Text(tr("High (256k)", "高音质 (256k)")).tag("256k")
                Text(tr("Medium (128k)", "中等 (128k)")).tag("128k")
                Text(tr("Data Saver (64k)", "省流 (64k)")).tag("64k")
            }
            .pickerStyle(.radioGroup)
            Text(tr("Affects yt-dlp download format selection for YouTube content.",
                    "影响 YouTube 内容的 yt-dlp 下载格式选择。"))
                .font(.caption).foregroundStyle(BrandColors.textSecondary)
        }

        Section(tr("Audio Nerd Mode", "音频极客模式")) {
            Toggle(tr("Show Audio Info Panel", "显示音频信息面板"), isOn: $audioNerd)
            Text(tr("Reveal codec/bitrate/sample rate/bit depth/channels/output device/EQ + spectrum. Unknown fields are never fabricated.",
                    "展示编码/比特率/采样率/位深/声道/输出设备/EQ + 频谱。未知字段绝不伪造。"))
                .font(.caption).foregroundStyle(BrandColors.textSecondary)
        }
    }
}