import SwiftUI

/// 歌词设置: 歌词来源选择(占位, 阶段 3 接入 LyricsService)。
struct LyricsSettingsView: View {
    @AppStorage(PrefKey.lyricsSource) private var lyricsSource: String = "lrclib"

    var body: some View {
        Section("歌词") {
            Picker("歌词来源", selection: $lyricsSource) {
                Text("LRCLIB(免费, 推荐)").tag("lrclib")
                Text("Musixmatch").tag("musixmatch")
                Text("本地 .lrc 文件").tag("local")
            }
            .pickerStyle(.radioGroup)
            Text("歌词来源将在阶段 3 实装; 当前仅显示占位。")
                .font(.caption).foregroundStyle(BrandColors.textSecondary)
        }
    }
}