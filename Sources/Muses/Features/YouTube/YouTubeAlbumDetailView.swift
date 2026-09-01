import SwiftUI
import SwiftData

/// Imported YouTube playlist detail using the shared collection composition.
struct YouTubeAlbumDetailView: View {
    let youTubeImport: YouTubeImport
    @Environment(PlaybackService.self) private var playback
    @Environment(YouTubeImportService.self) private var importService
    @Environment(InboxService.self) private var inbox
    @Environment(YouTubeAccountService.self) private var youTubeAccount
    @Environment(YouTubePlaylistSyncService.self) private var playlistSync
    @Environment(YouTubeSearchService.self) private var searchService
    @Query(sort: \Playlist.name) private var allPlaylists: [Playlist]
    @State private var syncing = false
    @State private var showDeleteConfirm = false
    @State private var showAddTrack = false
    @State private var writeError: String?
    @State private var rows: [CollectionTrackRow] = []
    @State private var pullPreview: YouTubePullPreview?
    @State private var pushPreview: YouTubePushPreview?

    private var isOwned: Bool {
        youTubeAccount.ownsPlaylist(youTubeImport.playlistId)
    }

    private var items: [YouTubeImportItem] {
        (youTubeImport.items ?? []).sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func playbackSnaps() -> [TrackSnapshot] {
        rows.map(\.snapshot)
    }

    var body: some View {
        CollectionPage(
            title: youTubeImport.title,
            subtitle: "\(metadataLine) • \(tr("Playlist Order", "歌单顺序"))",
            youTubeURL: URL(string: youTubeImport.url),
            rows: rows,
            defaultSort: .playlistOrder,
            currentTrack: playback.state.track,
            playlists: allPlaylists,
            emptyTitle: tr("Playlist is empty", "歌单为空"),
            emptySubtitle: tr(
                "Check Remote, then Pull changes or add a YouTube song",
                "检查远端后拉取变更，或添加 YouTube 歌曲"
            ),
            onPlay: { row in
                playback.playTrack(row.snapshot, context: playbackSnaps(), from: .import)
            },
            onRemove: isOwned ? { row in
                guard let item = items.first(where: { $0.id == row.id }) else { return }
                removeItem(item)
            } : nil
        ) {
            controls
        }
        .onAppear { reloadRows() }
        .sheet(isPresented: $showAddTrack) {
            AddToYouTubePlaylistSheet(youTubeImport: youTubeImport)
        }
        .sheet(item: $pullPreview) { preview in
            PlaylistPullPreviewSheet(preview: preview) { resolved in
                do {
                    try playlistSync.applyPull(preview, resolvedSnapshot: resolved)
                    writeError = nil
                    reloadRows()
                } catch {
                    writeError = error.localizedDescription
                }
            }
        }
        .sheet(item: $pushPreview) { preview in
            PlaylistPushPreviewSheet(preview: preview) {
                try await playlistSync.resumePush(batchID: preview.batchID)
            } onCancel: {
                try playlistSync.discardPush(batchID: preview.batchID)
            }
        }
        .confirmationDialog(
            tr("Delete this YouTube playlist import?",
               "删除此 YouTube 歌单导入?"),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(tr("Delete", "删除"), role: .destructive) {
                do {
                    try playlistSync.moveToRecentlyDeleted(importID: youTubeImport.id)
                    NotificationCenter.default.post(name: .musesCloseYouTubeAlbum, object: nil)
                } catch {
                    writeError = error.localizedDescription
                }
            }
            Button(tr("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(tr("The local playlist moves to Recently Deleted for 30 days. YouTube is not changed.",
                    "本地歌单会移入“最近删除”并保留 30 天；YouTube 不会被修改。"))
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                ChromeIconButton(
                    systemName: "chevron.backward",
                    help: tr("Back", "返回"),
                    accessibility: tr("Back", "返回")
                ) {
                    NotificationCenter.default.post(name: .musesCloseYouTubeAlbum, object: nil)
                }
                ChromeIconButton(
                    systemName: "play.fill",
                    help: tr("Play All", "播放全部"),
                    accessibility: tr("Play All", "播放全部"),
                    action: playAll
                )
                ChromeIconButton(
                    systemName: "shuffle",
                    help: tr("Shuffle", "随机播放"),
                    accessibility: tr("Shuffle", "随机播放"),
                    action: shuffleAll
                )
                ChromeIconButton(
                    systemName: "arrow.down.to.line",
                    help: tr("Pull from YouTube", "从 YouTube 拉取"),
                    accessibility: tr("Pull from YouTube", "从 YouTube 拉取")
                ) {
                    Task { await previewPull() }
                }
                .disabled(!youTubeAccount.isConnected || syncing)
                if isOwned {
                    ChromeIconButton(
                        systemName: "arrow.up.to.line",
                        help: tr("Push to YouTube", "推送到 YouTube"),
                        accessibility: tr("Push to YouTube", "推送到 YouTube")
                    ) { Task { await previewPush() } }
                    .disabled(syncing)
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

            if syncing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(tr("Syncing playlist", "正在同步歌单"))
            } else if isOwned {
                Text(tr("Edits stay local until you choose Push. Pull never writes YouTube.",
                        "编辑会先保存在本地，只有选择“推送”才会写入 YouTube；“拉取”不会写入 YouTube。"))
                    .font(.caption2)
                    .foregroundStyle(BrandColors.textSecondary)
            }

            if let writeError {
                Text(writeError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    /// Metadata: channel • track count • total duration.
    private var metadataLine: String {
        let count = items.count
        var parts: [String] = [youTubeImport.channel]
        parts.append("\(count) \(count == 1 ? tr("song", "首") : tr("songs", "首"))")
        let totalMs = items.reduce(0) { $0 + $1.durationMs }
        if totalMs > 0 {
            let totalSec = totalMs / 1000
            parts.append(formatDuration(Double(totalSec)))
        }
        return parts.joined(separator: " • ")
    }

    private func reloadRows() {
        rows = items.map { collectionRow(for: $0) }
    }

    private func collectionRow(for item: YouTubeImportItem) -> CollectionTrackRow {
        if let track = item.track {
            return CollectionTrackRow(track: track, canonicalIndex: item.order,
                                      collectionItemID: item.id)
        }
        return CollectionTrackRow(
            snapshot: snapshot(for: item),
            canonicalIndex: item.order,
            addedAt: youTubeImport.importedAt
        )
    }

    private func removeItem(_ item: YouTubeImportItem) {
        do {
            _ = try playlistSync.saveLocalRevision(importID: youTubeImport.id)
            guard importService.removeRemoteItem(
                importId: youTubeImport.id, itemId: item.id) else {
                throw YouTubeImportError.notFound
            }
            writeError = nil
            reloadRows()
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
            youTubeId: item.youTubeId,
            artworkUrl: YouTubeThumbnail.urlString(videoId: item.youTubeId),
            sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false
        )
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

    private func previewPull() async {
        syncing = true
        defer { syncing = false }
        do {
            pullPreview = try await playlistSync.checkRemote(importID: youTubeImport.id)
            writeError = nil
        } catch {
            writeError = error.localizedDescription
        }
    }

    private func previewPush() async {
        syncing = true
        defer { syncing = false }
        do {
            pushPreview = try await playlistSync.preparePush(importID: youTubeImport.id)
            writeError = nil
        } catch {
            writeError = error.localizedDescription
        }
    }

    private func formatDuration(_ s: Double) -> String {
        let mins = Int(s) / 60
        let secs = Int(s) % 60
        if mins >= 60 {
            return String(format: "%d:%02d:%02d", mins / 60, mins % 60, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }

}

/// Search-and-add sheet for owned YouTube playlists. Changes are staged locally;
/// the detail page's explicit Push performs the remote write.
