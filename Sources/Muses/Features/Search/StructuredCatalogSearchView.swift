import AppKit
import SwiftUI

struct StructuredCatalogSearchView: View {
    @Environment(GlobalSearchService.self) private var search
    @Environment(PlaybackService.self) private var playback
    @State private var playbackError = false
    private var browser: MusicCatalogBrowser { search.musicCatalog }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(browser.detail?.title ?? "YouTube Music").font(.title3.weight(.semibold))
                Spacer()
                if browser.loading { ProgressView().controlSize(.small) }
            }
            if browser.detail == nil {
                Picker(tr("Category", "类别", zhHant: "類別"), selection: Binding(get: { browser.kind }, set: { browser.search(search.query, kind: $0) })) {
                    Text(tr("All", "全部")).tag(MusicCatalogKind?.none)
                    ForEach(MusicCatalogKind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(Optional(kind))
                    }
                }.pickerStyle(.menu).fixedSize()
            }
            if browser.failed {
                HStack {
                    Text(browser.isStale
                         ? tr("Refresh failed. Showing saved results.", "刷新失败，正在显示缓存结果。", zhHant: "重新整理失敗，正在顯示快取結果。")
                         : tr("YouTube Music could not load these results.", "无法加载这些 YouTube Music 结果。", zhHant: "無法載入這些 YouTube Music 結果。"))
                    Button(tr("Retry", "重试", zhHant: "重試")) { browser.retry() }.disabled(browser.loading)
                }.font(.callout)
            }
            if playbackError {
                Text(tr("Playback could not start. Please try again.", "无法开始播放，请重试。", zhHant: "無法開始播放，請再試一次。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if browser.detail == nil && browser.kind == nil {
                ForEach(MusicCatalogKind.allCases, id: \.self) { kind in
                    let items = browser.items.filter { $0.kind == kind }
                    if !items.isEmpty {
                        HStack {
                            Text(kind.title).font(.headline)
                            Spacer()
                            Button(tr("See all", "查看全部", zhHant: "查看全部")) { browser.search(search.query, kind: kind) }
                                .accessibilityLabel(tr("See all", "查看全部", zhHant: "查看全部") + " " + kind.title)
                        }
                        ForEach(items.prefix(5)) { item in row(item) }
                    }
                }
            } else {
                // Offset preserves repeated source playlist occurrences.
                ForEach(Array(browser.items.enumerated()), id: \.offset) { index, item in row(item, index: index) }
            }
            if !browser.relatedItems.isEmpty {
                Text(tr("Related on YouTube Music", "YouTube Music 关联内容", zhHant: "YouTube Music 關聯內容")).font(.headline)
                ForEach(browser.relatedItems) { item in row(item, related: true) }
            }
            if browser.items.isEmpty && browser.relatedItems.isEmpty && !browser.loading && !browser.failed && browser.fetchedAt != nil {
                Text(tr("No results available.", "暂无可用结果。", zhHant: "暫無可用結果。"))
                    .foregroundStyle(.secondary)
            }
            if browser.nextCursor != nil {
                Button(tr("Load more", "加载更多", zhHant: "載入更多")) { browser.more() }.disabled(browser.loading)
            }
            if let fetched = browser.fetchedAt {
                HStack(spacing: 5) {
                    Text("YouTube Music · \(browser.region)")
                    Text(fetched, style: .date)
                    Text(fetched, style: .time)
                }.font(.caption).foregroundStyle(.secondary)
            }
            Divider().padding(.vertical, 8)
        }
        .task(id: search.query + "|" + search.scope.rawValue) {
            browser.clear()
            guard search.scope.searchesYouTube, !search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard !Task.isCancelled, !search.wasCancelled else { return }
            browser.search(search.query)
        }
        .onDisappear { browser.cancel() }
    }

    @ViewBuilder
    private func row(_ item: MusicCatalogItem, index: Int? = nil, related: Bool = false) -> some View {
        if let entry = item.playableEntry {
            rowContent(item, index: index, related: related).youTubeEntryContextMenu(entry: entry) { activate(item, index: index, related: related) }
        } else { rowContent(item, index: index, related: related) }
    }

    private func rowContent(_ item: MusicCatalogItem, index: Int?, related: Bool) -> some View {
        HStack(spacing: 10) {
            ArtworkView(source: ArtworkSource.resolve(remoteURL: (item.artwork ?? browser.detail?.artwork)?.absoluteString,
                                                       youTubeId: item.id.hasPrefix("video:") ? String(item.id.dropFirst(6)) : nil),
                        cornerRadius: 5, glyphSize: 16, targetSize: 42)
                .frame(width: 42, height: 42).accessibilityHidden(true)
            Button { activate(item, index: index, related: related) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).lineLimit(1)
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if item.playableEntry != nil {
                Button { activate(item, index: index, related: related) } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.plain).help(tr("Play", "播放"))
                    .accessibilityLabel(tr("Play", "播放") + " " + item.title)
            }
        }.padding(.vertical, 3)
    }

    private func activate(_ item: MusicCatalogItem, index: Int? = nil, related: Bool = false) {
        if item.id.hasPrefix("browse:") { browser.open(item); return }
        guard let entry = item.playableEntry, let resolver = search.youTubeSearch else {
            if item.id.hasPrefix("video:"), let url = URL(string: "https://music.youtube.com/watch?v=" + item.id.dropFirst(6)) { NSWorkspace.shared.open(url) }
            return
        }
        let contextItems = related ? browser.relatedItems : browser.items
        let entries = contextItems.compactMap(\.playableEntry)
        let selectedIndex = index.map { contextItems.prefix($0).compactMap(\.playableEntry).count }
        Task {
            do {
                let snapshot = try await resolver.resolveTrack(entry: entry)
                playbackError = false
                playback.playTrack(snapshot, context: TrackSnapshot.playbackContext(playing: snapshot, youTubeEntries: entries, selectedIndex: selectedIndex), from: .search)
            } catch { playbackError = true }
        }
    }
}

extension MusicCatalogKind {
    var title: String {
        switch self {
        case .song: tr("Songs", "歌曲")
        case .video: tr("Videos", "视频", zhHant: "影片")
        case .album: tr("Albums", "专辑", zhHant: "專輯")
        case .artist: tr("Artists", "艺人", zhHant: "藝人")
        case .playlist: tr("Playlists", "歌单", zhHant: "播放列表")
        case .podcast: tr("Podcasts", "播客")
        case .episode: tr("Episodes", "单集", zhHant: "單集")
        }
    }
}
