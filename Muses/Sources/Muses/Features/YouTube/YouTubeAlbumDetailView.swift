import SwiftUI
import AppKit

/// YouTube 歌单(专辑)的现代详情视图:大封面 + 标题 + 频道 + 曲目列表。
///
/// 镜像 `AlbumDetailView` 的布局风格,数据来自 `YouTubeImport`(已导入的 YT 歌单)。
/// 通过 `.musesNavigateYouTubeImport` 通知从侧边栏导入卡片或搜索结果打开。
struct YouTubeAlbumDetailView: View {
    let youTubeImport: YouTubeImport
    @Environment(PlaybackService.self) private var playback
    @Environment(YouTubeImportService.self) private var importService
    @Environment(InboxService.self) private var inbox
    @Environment(YouTubeAccountService.self) private var youTubeAccount
    @Environment(YouTubeSearchService.self) private var searchService
    @State private var gradient: [Color] = [BrandColors.background, BrandColors.surface]
    @State private var syncing = false
    @State private var showDeleteConfirm = false
    @State private var pendingDelete = false
    @State private var selectedRowID: UUID?
    @State private var showAddTrack = false
    @State private var writeError: String?

    private var isOwned: Bool {
        youTubeAccount.ownsPlaylist(youTubeImport.playlistId)
    }

    private var items: [YouTubeImportItem] {
        (youTubeImport.items ?? []).sorted { $0.order < $1.order }
    }
    private var localAdditions: [Track] {
        youTubeImport.localAdditions ?? []
    }

    /// Playback context. Built on play, not during `body`.
    private func playbackSnaps() -> [TrackSnapshot] {
        let yt = items.compactMap { $0.track }.map { TrackSnapshot(from: $0) }
        let local = localAdditions.map { TrackSnapshot(from: $0) }
        return yt + local
    }

    var body: some View {
        ZStack {
            BrandColors.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 16)
                trackList
                    .padding(.horizontal, 8)
                    .padding(.bottom, 100)
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    NotificationCenter.default.post(name: .musesCloseYouTubeAlbum, object: nil)
                } label: { Image(systemName: "chevron.backward") }
            }
        }
        .onAppear { extractGradient() }
        .sheet(isPresented: $showAddTrack) {
            AddToYouTubePlaylistSheet(youTubeImport: youTubeImport)
        }
        .confirmationDialog(
            tr("Delete this YouTube playlist import?",
               "删除此 YouTube 歌单导入?"),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(tr("Delete", "删除"), role: .destructive) {
                pendingDelete = true
                importService.deleteImport(importId: youTubeImport.id)
                NotificationCenter.default.post(name: .musesCloseYouTubeAlbum, object: nil)
            }
            Button(tr("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(tr("Imported tracks remain in your library unless you delete them separately.",
                    "已导入曲目仍保留在资料库中,除非单独删除。"))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            artwork
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(radius: 16)
            VStack(alignment: .leading, spacing: 10) {
                Text(youTubeImport.title)
                    .font(.largeTitle).fontWeight(.bold)
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    YouTubeMark(size: 14)
                    Text(metadataLine)
                        .font(.subheadline)
                        .foregroundStyle(BrandColors.textSecondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    ChromeIconButton(
                        systemName: "play.fill",
                        help: tr("Play", "播放"),
                        accessibility: tr("Play", "播放"),
                        action: playAll
                    )
                    ChromeIconButton(
                        systemName: "shuffle",
                        help: tr("Shuffle", "随机播放"),
                        accessibility: tr("Shuffle", "随机播放"),
                        action: shuffleAll
                    )
                    Button {
                        if let url = URL(string: youTubeImport.url) { NSWorkspace.shared.open(url) }
                    } label: {
                        YouTubeMark(size: 16)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help(tr("Open on YouTube", "在 YouTube 打开"))
                    .accessibilityLabel(tr("Open on YouTube", "在 YouTube 打开"))

                    ChromeIconButton(
                        systemName: "arrow.clockwise",
                        help: tr("Resync", "重新同步"),
                        accessibility: tr("Resync", "重新同步")
                    ) {
                        Task {
                            syncing = true
                            _ = try? await importService.resync(importId: youTubeImport.id)
                            syncing = false
                        }
                    }

                    ChromeIconButton(
                        systemName: "trash",
                        help: tr("Delete", "删除"),
                        accessibility: tr("Delete", "删除")
                    ) { showDeleteConfirm = true }
                    if isOwned {
                        ChromeIconButton(
                            systemName: "plus",
                            help: tr("Add Tracks", "添加曲目"),
                            accessibility: tr("Add Tracks", "添加曲目")
                        ) { showAddTrack = true }
                    }
                }
                .padding(.top, 4)
                if isOwned {
                    Text(tr("Edits sync to YouTube Music", "编辑会同步到 YouTube Music"))
                        .font(.caption2)
                        .foregroundStyle(BrandColors.textSecondary)
                }
                if let writeError {
                    Text(writeError).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
        }
        .contextMenu {
            Button(tr("Play", "播放")) { playAll() }
            Button(tr("Shuffle", "随机播放")) { shuffleAll() }
            Button(tr("Open on YouTube", "在 YouTube 打开")) {
                if let url = URL(string: youTubeImport.url) { NSWorkspace.shared.open(url) }
            }
            Button(tr("Resync", "重新同步")) {
                Task { _ = try? await importService.resync(importId: youTubeImport.id) }
            }
            Divider()
            Button(tr("Delete", "删除"), role: .destructive) { showDeleteConfirm = true }
        }
    }

    /// 元数据:频道 • 曲目数 • 总时长。
    private var metadataLine: String {
        let count = items.count + localAdditions.count
        var parts: [String] = [youTubeImport.channel]
        parts.append("\(count) \(count == 1 ? tr("song", "首") : tr("songs", "首"))")
        let totalMs = items.reduce(0) { $0 + $1.durationMs }
        if totalMs > 0 {
            let totalSec = totalMs / 1000
            parts.append(formatDuration(Double(totalSec)))
        }
        return parts.joined(separator: " • ")
    }

    // MARK: - Artwork

    private var artwork: some View {
        Group {
            if let urlStr = youTubeImport.artworkUrl, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() }
                    else { thumbnailFallback }
                }
            } else {
                thumbnailFallback
            }
        }
        .clipped().cornerRadius(12)
    }

    /// 用首条 YT 视频缩略图作为封面回退。
    private var thumbnailFallback: some View {
        Group {
            if let first = items.first {
                CachedAsyncImage(
                    url: YouTubeThumbnail.url(videoId: first.youTubeId),
                    content: { $0.resizable().scaledToFill() },
                    placeholder: { placeholder }
                )
            } else {
                placeholder
            }
        }
    }
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 12).fill(BrandColors.surface)
            .overlay(Image(systemName: "music.note.list")
                .font(.largeTitle).foregroundStyle(BrandColors.textSecondary.opacity(0.5)))
    }

    // MARK: - Track list

    private var trackList: some View {
        List {
            ForEach(items, id: \.id) { item in
                SongObjectView(
                    title: item.title,
                    artist: item.artist,
                    durationLabel: item.durationMs > 0 ? formatMs(item.durationMs) : nil,
                    indexLabel: "\(item.order + 1)",
                    artwork: importItemArtwork(item),
                    isSelected: selectedRowID == item.id,
                    nowPlayingID: playback.state.track?.youTubeId == item.youTubeId
                    ? playback.state.track?.id : nil,
                    showsHoverPlay: true,
                    showsPlayButton: true,
                    onSelect: { selectedRowID = item.id },
                    onPlay: { playItem(item) },
                    onRemove: removeAction(for: item),
                    onQueue: {
                        playback.queue.addToQueue(snapshot(for: item))
                    },
                    onInbox: {
                        inbox.add(snapshot(for: item), source: .youTubeImport)
                    }
                )
                .trackContextMenu(snapshot: TrackSnapshot(
                                      id: item.track?.id ?? item.id,
                                      title: item.title,
                                      artist: item.artist,
                                      albumTitle: youTubeImport.title,
                                      durationSeconds: Double(item.durationMs) / 1000,
                                      filePath: nil,
                                      youTubeId: item.youTubeId,
                                      artworkHash: nil,
                                      artworkUrl: YouTubeThumbnail.urlString(videoId: item.youTubeId),
                                      sampleRate: nil,
                                      bitDepth: nil,
                                      codec: nil,
                                      isLossless: false),
                                  track: nil,
                                  onPlay: { playItem(item) })
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .onMove(perform: moveItems)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .focusEffectDisabled()
    }

    private func moveItems(from source: IndexSet, to destination: Int) {
        guard isOwned, let from = source.first else { return }
        let adjusted = destination > from ? destination - 1 : destination
        let videoId = items[from].youTubeId
        _ = importService.moveRemoteItem(importId: youTubeImport.id, from: from, to: adjusted)
        Task { await writeMove(videoId: videoId, to: adjusted) }
    }

    private func removeAction(for item: YouTubeImportItem) -> (() -> Void)? {
        guard isOwned else { return nil }
        return { removeItem(item) }
    }

    private func removeItem(_ item: YouTubeImportItem) {
        let videoId = item.youTubeId
        _ = importService.removeRemoteItem(importId: youTubeImport.id, itemId: item.id)
        Task { await writeRemove(videoId: videoId) }
    }

    private func writeMove(videoId: String, to position: Int) async {
        guard isOwned, let writer = youTubeAccount.playlistWriter() else { return }
        do {
            try await writer.moveVideo(playlistId: youTubeImport.playlistId, videoId: videoId, to: position)
            writeError = nil
        } catch {
            writeError = error.localizedDescription
        }
    }

    private func writeRemove(videoId: String) async {
        guard isOwned, let writer = youTubeAccount.playlistWriter() else { return }
        do {
            try await writer.removeVideo(playlistId: youTubeImport.playlistId, videoId: videoId)
            writeError = nil
        } catch {
            writeError = error.localizedDescription
        }
    }

    private func snapshot(for item: YouTubeImportItem) -> TrackSnapshot {
        if let t = item.track { return TrackSnapshot(from: t) }
        return TrackSnapshot(
            id: item.id,
            title: item.title,
            artist: item.artist,
            albumTitle: youTubeImport.title,
            durationSeconds: Double(item.durationMs) / 1000,
            filePath: nil,
            youTubeId: item.youTubeId,
            artworkHash: nil,
            artworkUrl: YouTubeThumbnail.urlString(videoId: item.youTubeId),
            sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false
        )
    }

    private func playItem(_ item: YouTubeImportItem) {
        let snap = snapshot(for: item)
        let ctx = playbackSnaps()
        guard let target = ctx.first(where: { $0.id == snap.id }) ?? ctx.first else { return }
        playback.playTrack(target, context: ctx, from: .import)
    }

    private func playAll() {
        let snaps = playbackSnaps()
        guard let first = snaps.first else { return }
        playback.playTrack(first, context: snaps, from: .import)
    }

    private func shuffleAll() {
        let snaps = playbackSnaps()
        guard !snaps.isEmpty else { return }
        let shuffled = snaps.shuffled()
        guard let first = shuffled.first else { return }
        playback.playTrack(first, context: shuffled, from: .import)
    }

    // MARK: - Gradient

    private func extractGradient() {
        // 从封面 URL 提取主色调(异步加载后用 NSImage)
        let urlStr = youTubeImport.artworkUrl
            ?? items.first.map { YouTubeThumbnail.urlString(videoId: $0.youTubeId) }
        guard let urlStr, let url = URL(string: urlStr) else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let img = NSImage(data: data) else { return }
            let colors = AlbumArtworkExtractor.dominantColors(img, count: 4)
            Task { @MainActor in
                gradient = colors.map { Color(nsColor: $0) } + [BrandColors.background]
            }
        }.resume()
    }

    private func formatDuration(_ s: Double) -> String {
        let mins = Int(s) / 60
        let secs = Int(s) % 60
        if mins >= 60 {
            return String(format: "%d:%02d:%02d", mins / 60, mins % 60, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }

    private func formatMs(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func importItemArtwork(_ item: YouTubeImportItem) -> ArtworkSource {
        if let url = YouTubeThumbnail.url(videoId: item.youTubeId) {
            return .remote(url)
        }
        return .placeholder
    }
}

/// Search-and-add sheet for owned YouTube playlists. Writes back through Data API.
struct AddToYouTubePlaylistSheet: View {
    let youTubeImport: YouTubeImport
    @Environment(\.dismiss) private var dismiss
    @Environment(YouTubeSearchService.self) private var searchService
    @Environment(YouTubeImportService.self) private var importService
    @Environment(YouTubeAccountService.self) private var youTubeAccount
    @State private var query = ""
    @State private var results: [YTDlpBridge.YTDlpPlaylistEntry] = []
    @State private var searching = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(tr("Add to playlist", "添加到歌单"))
                    .font(.headline)
                Spacer()
                Button(tr("Done", "完成")) { dismiss() }
            }
            TextField(tr("Search YouTube", "搜索 YouTube"), text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await runSearch() } }
            if searching { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            List(results, id: \.id) { entry in
                Button {
                    Task { await add(entry) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).foregroundStyle(BrandColors.textPrimary)
                        Text(entry.uploader ?? "")
                            .font(.caption)
                            .foregroundStyle(BrandColors.textSecondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .padding(16)
        .frame(width: 420, height: 480)
        .musesFloatingChrome(cornerRadius: 16)
        .onTapGesture {}
    }

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searching = true
        defer { searching = false }
        do {
            results = try await searchService.search(query: q, limit: 12)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func add(_ entry: YTDlpBridge.YTDlpPlaylistEntry) async {
        _ = importService.addRemoteVideo(
            importId: youTubeImport.id,
            videoId: entry.id,
            title: entry.title,
            artist: entry.uploader ?? youTubeImport.channel,
            durationMs: Int((entry.duration ?? 0) * 1000))
        if youTubeAccount.ownsPlaylist(youTubeImport.playlistId),
           let writer = youTubeAccount.playlistWriter() {
            do {
                try await writer.addVideo(playlistId: youTubeImport.playlistId, videoId: entry.id)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}