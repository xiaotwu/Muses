import SwiftUI

struct LyricsMatchPicker: View {
    let track: TrackSnapshot
    @Environment(LyricsService.self) private var lyrics
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [LyricsCandidate] = []
    @State private var loading = true
    @State private var titleQuery = ""
    @State private var artistQuery = ""
    @State private var source = "auto"
    @State private var searchRevision = 0
    @State private var initializedQuery = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(tr("Match Lyrics", "匹配歌词")).font(.title2.bold())
                Spacer()
                Button(tr("Close", "关闭"), systemImage: "xmark") { dismiss() }
                    .labelStyle(ActionIconLabelStyle())
                    .help(tr("Close", "关闭")).keyboardShortcut(.cancelAction)
            }
            Text(track.title + " · " + track.artist).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                TextField(tr("Song title", "歌名", zhHant: "歌名"), text: $titleQuery)
                TextField(tr("Artist", "艺人", zhHant: "藝人"), text: $artistQuery)
                Button { searchRevision += 1 } label: {
                    Image(systemName: "magnifyingglass").frame(width: 28, height: 28)
                }.musesAction()
                .help(tr("Search lyrics", "搜索歌词", zhHant: "搜尋歌詞"))
                .accessibilityLabel(tr("Search lyrics", "搜索歌词", zhHant: "搜尋歌詞"))
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit { searchRevision += 1 }
            Picker(tr("Source", "来源", zhHant: "來源"), selection: $source) {
                Text(tr("All sources", "全部来源", zhHant: "全部來源")).tag("auto")
                Text("LRCLIB").tag("lrclib")
                Text("Musixmatch").tag("musixmatch")
                Text("Lyrics.ovh").tag("lyricsOVH")
            }.pickerStyle(.menu)
            if loading {
                ProgressView(tr("Finding matching recordings…", "正在查找匹配的录音版本…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if candidates.isEmpty {
                ContentUnavailableView(tr("No lyric matches", "未找到歌词匹配"), systemImage: "text.magnifyingglass",
                    description: Text(tr("Check the track's title and artist, then try again.", "请检查曲目标题和艺人后重试。")))
            } else {
                List(candidates) { candidate in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(candidate.trackName).font(.headline)
                        Text([candidate.artistName, candidate.albumName].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text(candidate.source.displayName)
                            if let duration = candidate.duration { Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))) }
                            if candidate.syncedLyrics?.isEmpty == false { Text(tr("Synced", "逐行同步")) }
                        }.font(.caption).foregroundStyle(.secondary)
                        Text(String((candidate.plainLyrics ?? candidate.syncedLyrics ?? "").prefix(200)))
                            .font(.caption).lineLimit(3)
                        Button(tr("Use these lyrics", "使用此歌词")) {
                            lyrics.choose(candidate, for: track)
                            dismiss()
                        }.musesAction()
                    }.padding(.vertical, 8)
                }.listStyle(.inset)
            }
        }
        .padding(24)
        .frame(width: 560, height: 600)
        .task(id: source + ":" + String(searchRevision)) {
            if !initializedQuery {
                titleQuery = LyricsService.sanitizedTitle(track.title)
                artistQuery = LyricsMatchPolicy.queryArtist(track.artist)
                initializedQuery = true
            }
            loading = true
            candidates = []
            let query = LyricsSearchQuery(title: titleQuery, artist: artistQuery).applying(to: track)
            let found = await lyrics.findCandidates(track: query, refresh: true, source: source)
            guard !Task.isCancelled else { return }
            candidates = found
            loading = false
        }
    }
}
