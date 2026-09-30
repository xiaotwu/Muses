import SwiftUI

struct LyricsMatchPicker: View {
    let track: TrackSnapshot
    @Environment(LyricsService.self) private var lyrics
    @Environment(YouTubeImportService.self) private var importService
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [LyricsCandidate] = []
    @State private var loading = true
    @State private var titleQuery = ""
    @State private var artistQuery = ""
    @State private var source = "auto"
    @State private var searchRevision = 0
    @State private var initializedQuery = false
    @State private var songInformation: SongDisplayInformation?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(tr("Match Lyrics", "匹配歌词")).font(.title2.bold())
                Spacer()
                Button(tr("Close", "关闭"), systemImage: "xmark") { dismiss() }
                    .labelStyle(ActionIconLabelStyle())
                    .help(tr("Close", "关闭")).keyboardShortcut(.cancelAction)
            }
            Text((songInformation?.title ?? track.title) + " · " + (songInformation?.artist ?? track.artist)).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                TextField(tr("Song title", "歌名", zhHant: "歌名"), text: $titleQuery)
                TextField(tr("Artist (optional)", "艺人（可留空）"), text: $artistQuery)
                Button { searchRevision += 1 } label: {
                    Image(systemName: "magnifyingglass").frame(width: 28, height: 28)
                }.musesAction()
                .help(tr("Search lyrics", "搜索歌词", zhHant: "搜尋歌詞"))
                .accessibilityLabel(tr("Search lyrics", "搜索歌词", zhHant: "搜尋歌詞"))
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit { searchRevision += 1 }
            Text(tr("Search also tries title-only and keyword matches. Confirm the recording before choosing.",
                    "会同时尝试仅歌名和关键词搜索，请确认录音版本后选择。"))
                .font(.caption).foregroundStyle(.secondary)
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
                    description: Text(tr("Try the original song title or leave artist blank. A source may also be temporarily unavailable.",
                                         "可尝试原始歌名或留空艺人字段；歌词来源也可能暂不可用。")))
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
        .task(id: track.youTubeId) {
            initializeQuery()
            let initialTitle = titleQuery
            let initialArtist = artistQuery
            let metadata = await importService.songMetadata(videoID: track.youTubeId)
            guard !Task.isCancelled, let metadata else { return }
            let information = SongDisplayInformation(row: importService.songPresentationRow(for: track), metadata: metadata)
            songInformation = information
            guard searchRevision == 0, titleQuery == initialTitle, artistQuery == initialArtist else { return }
            let title = LyricsService.sanitizedTitle(information.title)
            let artist = queryArtist(information)
            if title != titleQuery || artist != artistQuery {
                titleQuery = title
                artistQuery = artist
                searchRevision += 1
            }
        }
        .task(id: source + ":" + String(searchRevision)) {
            initializeQuery()
            loading = true
            candidates = []
            let query = LyricsSearchQuery(title: titleQuery, artist: artistQuery).applying(to: track)
            let found = await lyrics.findCandidates(track: query, refresh: true, source: source)
            guard !Task.isCancelled else { return }
            candidates = found
            loading = false
        }
    }

    private func initializeQuery() {
        guard !initializedQuery else { return }
        let information = SongDisplayInformation(row: importService.songPresentationRow(for: track))
        songInformation = information
        titleQuery = LyricsService.sanitizedTitle(information.title)
        artistQuery = queryArtist(information)
        initializedQuery = true
    }

    private func queryArtist(_ information: SongDisplayInformation) -> String {
        information.artist == tr("Artist unavailable", "艺人信息暂缺")
            ? "" : LyricsMatchPolicy.queryArtist(information.artist)
    }

}
