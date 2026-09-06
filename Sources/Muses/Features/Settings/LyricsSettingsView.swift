import SwiftUI

/// Lyrics source selection for YouTube-backed tracks.
struct LyricsSettingsView: View {
    @AppStorage(PrefKey.lyricsSource) private var lyricsSource: String = "lrclib"

    var body: some View {
        Section(tr("Lyrics", "歌词")) {
            Picker(tr("Lyrics Source", "歌词来源"), selection: $lyricsSource) {
                Text(tr("LRCLIB (Recommended)", "LRCLIB (推荐)")).tag("lrclib")
                Text(tr("Musixmatch", "Musixmatch")).tag("musixmatch")
            }
            .pickerStyle(.radioGroup)
        }
    }
}
