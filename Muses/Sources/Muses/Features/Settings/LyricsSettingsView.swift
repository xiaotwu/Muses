import SwiftUI

/// 歌词设置: 歌词来源选择。所选来源失败时自动回退到 LRCLIB 再本地 .lrc。
struct LyricsSettingsView: View {
    @AppStorage(PrefKey.lyricsSource) private var lyricsSource: String = "lrclib"

    var body: some View {
        Section(tr("Lyrics", "歌词")) {
            Picker(tr("Lyrics Source", "歌词来源"), selection: $lyricsSource) {
                Text(tr("LRCLIB (free, recommended)", "LRCLIB(免费, 推荐)")).tag("lrclib")
                Text(tr("Musixmatch", "Musixmatch")).tag("musixmatch")
                Text(tr("Local .lrc files", "本地 .lrc 文件")).tag("local")
            }
            .pickerStyle(.radioGroup)
            Text(tr("When the selected source misses, automatically falls back to LRCLIB then local .lrc; YouTube audio has no local .lrc.", "所选来源未命中时自动回退到 LRCLIB 再本地 .lrc;YouTube 音轨无本地 .lrc。"))
                .font(.caption).foregroundStyle(BrandColors.textSecondary)
        }
    }
}