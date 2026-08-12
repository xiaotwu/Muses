import SwiftUI

/// 歌词设置: 歌词来源选择。所选来源失败时自动回退到 LRCLIB 再本地 .lrc。
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
            Text("所选来源未命中时自动回退到 LRCLIB 再本地 .lrc;YouTube 音轨无本地 .lrc。")
                .font(.caption).foregroundStyle(BrandColors.textSecondary)
        }
    }
}