import SwiftUI

/// YouTube 搜索服务的环境注入键。
private struct YouTubeSearchServiceEnvironmentKey: EnvironmentKey {
    static let defaultValue: YouTubeSearchService? = nil
}

extension EnvironmentValues {
    var youTubeSearchService: YouTubeSearchService? {
        get { self[YouTubeSearchServiceEnvironmentKey.self] }
        set { self[YouTubeSearchServiceEnvironmentKey.self] = newValue }
    }
}

/// YouTube 搜索页:输入关键词 → yt-dlp 搜索 → 结果列表 → 导入为 Track / 加入队列。
struct YouTubeSearchView: View {
    @Environment(YouTubeSearchService.self) private var searchService
    @Environment(PlaybackService.self) private var playback

    @State private var query = ""
    @State private var results: [YTDlpBridge.YTDlpPlaylistEntry] = []
    @State private var searching = false
    @State private var error: String?
    @State private var importedIds: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            // 搜索栏
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(BrandColors.textSecondary)
                TextField(tr("Search YouTube songs, artists…", "搜索 YouTube 歌曲、艺术家…"), text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await runSearch() } }
                if searching {
                    ProgressView().controlSize(.small)
                } else if !query.isEmpty {
                    Button {
                        query = ""
                        results = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(BrandColors.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(BrandColors.surface)
            .cornerRadius(10)
            .padding(16)

            // 错误提示
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(BrandColors.magenta)
                    .padding(.horizontal, 16)
            }

            // 结果列表
            if results.isEmpty && !searching {
                Spacer()
                Text(query.isEmpty ? tr("Enter keywords to search YouTube", "输入关键词搜索 YouTube") : tr("No results", "无结果"))
                    .font(.callout)
                    .foregroundStyle(BrandColors.textSecondary)
                Spacer()
            } else {
                List {
                    ForEach(results, id: \.id) { entry in
                        YouTubeSearchResultRow(
                            entry: entry,
                            isImported: importedIds.contains(entry.id),
                            onImport: { Task { await importEntry(entry) } },
                            onPlay: { Task { await playEntry(entry) } }
                        )
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(BrandColors.background)
    }

    private func runSearch() async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        searching = true
        error = nil
        do {
            results = try await searchService.search(query: query)
        } catch {
            self.error = error.localizedDescription
            results = []
        }
        searching = false
    }

    private func importEntry(_ entry: YTDlpBridge.YTDlpPlaylistEntry) async {
        do {
            _ = try await searchService.importAsTrack(entry: entry)
            importedIds.insert(entry.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func playEntry(_ entry: YTDlpBridge.YTDlpPlaylistEntry) async {
        // 先导入再播放
        do {
            let snap = try await searchService.importAsTrack(entry: entry)
            importedIds.insert(entry.id)
            playback.playTrack(snap, context: [snap], from: .search)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 单条搜索结果行。
struct YouTubeSearchResultRow: View {
    let entry: YTDlpBridge.YTDlpPlaylistEntry
    let isImported: Bool
    let onImport: () -> Void
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // 缩略图
            AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(entry.id)/hqdefault.jpg")) { phase in
                if let img = phase.image { img.resizable().scaledToFill() }
                else {
                    Rectangle().fill(BrandColors.surface)
                        .overlay(Image(systemName: "music.note").foregroundStyle(BrandColors.textSecondary))
                }
            }
            .frame(width: 80, height: 45)
            .cornerRadius(6)
            .clipped()

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
                Text(entry.uploader ?? tr("Unknown", "未知"))
                    .font(.caption).foregroundStyle(BrandColors.textSecondary).lineLimit(1)
            }

            Spacer()

            if let dur = entry.duration {
                Text(format(dur)).font(.caption2).foregroundStyle(BrandColors.textSecondary)
            }

            Button(action: onPlay) {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(BrandColors.magenta)
            .help(tr("Play", "播放"))

            Button(action: onImport) {
                Image(systemName: isImported ? "checkmark.circle.fill" : "plus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(isImported ? BrandColors.green : BrandColors.cyan)
            .help(isImported ? tr("Imported", "已导入") : tr("Import to library", "导入到资料库"))
        }
        .padding(.vertical, 4)
    }

    private func format(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}