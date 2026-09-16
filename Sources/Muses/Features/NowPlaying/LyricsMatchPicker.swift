import SwiftUI

struct LyricsMatchPicker: View {
    let track: TrackSnapshot
    @Environment(LyricsService.self) private var lyrics
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [LyricsCandidate] = []
    @State private var loading = true

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
                            Text("LRCLIB")
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
        .frame(width: 480, height: 500)
        .task {
            candidates = await lyrics.findCandidates(track: track, refresh: true)
            guard !Task.isCancelled else { return }
            loading = false
        }
    }
}
