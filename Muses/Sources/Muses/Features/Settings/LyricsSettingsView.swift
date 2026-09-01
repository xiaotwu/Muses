import SwiftUI

/// Lyrics source selection for YouTube-backed tracks.
struct LyricsSettingsView: View {
    @AppStorage(PrefKey.lyricsSource) private var lyricsSource: String = "lrclib"

    var body: some View {
        Section(tr("Lyrics", "歌词")) {
            Picker(tr("Lyrics Source", "歌词来源"), selection: $lyricsSource) {
                Text(tr("LRCLIB (free, recommended)", "LRCLIB(免费, 推荐)")).tag("lrclib")
                Text(tr("Musixmatch", "Musixmatch")).tag("musixmatch")
            }
            .pickerStyle(.radioGroup)
            Text(tr("When the selected source misses, Muses falls back to LRCLIB. Decorations such as “(Official Video)” are removed before lookup.",
                    "所选来源未命中时会回退到 LRCLIB；检索前会移除“(Official Video)”等标题装饰。"))
                .font(.caption).foregroundStyle(BrandColors.textSecondary)
        }
    }
}
