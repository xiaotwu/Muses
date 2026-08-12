import SwiftUI

/// 音质设置: 本地/YouTube 音质偏好(占位, 阶段 3+ 实装)。
struct AudioQualitySettingsView: View {
    @AppStorage(PrefKey.audioQuality) private var audioQuality: String = "native"

    var body: some View {
        Section("音质") {
            Picker("本地音质", selection: $audioQuality) {
                Text("原始(Native)").tag("native")
                Text("独占模式(Exclusive)").tag("exclusive")
            }
            .pickerStyle(.radioGroup)
            Text("独占模式将在阶段 4 通过 CoreAudio HAL 实装, 当前仅原始模式生效。")
                .font(.caption).foregroundStyle(BrandColors.textSecondary)

            Divider().padding(.vertical, 4)

            Picker("YouTube 音质", selection: $audioQuality) {
                Text("最高(bestaudio)").tag("bestaudio")
                Text("省流(128k)").tag("128k")
            }
            .pickerStyle(.radioGroup)
            Text("YouTube 音质偏好将影响 yt-dlp 下载格式选择, 阶段 3 实装。")
                .font(.caption).foregroundStyle(BrandColors.textSecondary)
        }
    }
}