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
    @State private var gradient: [Color] = [BrandColors.background, BrandColors.surface]
    @State private var syncing = false
    @State private var showAddLocalSheet = false
    @State private var showDeleteConfirm = false
    @State private var pendingDelete = false
    @State private var selectedRowID: UUID?

    private var items: [YouTubeImportItem] {
        (youTubeImport.items ?? []).sorted { $0.order < $1.order }
    }
    private var localAdditions: [Track] {
        youTubeImport.localAdditions ?? []
    }

    /// 合并播放上下文:YT 条目对应的 Track + 本地附加(按顺序)。
    private var allSnaps: [TrackSnapshot] {
        let yt = items.compactMap { $0.track }.map { TrackSnapshot(from: $0) }
        let local = localAdditions.map { TrackSnapshot(from: $0) }
        return yt + local
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: gradient, startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    trackList
                }
                .padding(24)
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
            Text(tr("Local additions and imported tracks remain in your library unless you delete them separately.",
                    "本地附加与已导入曲目仍保留在资料库中,除非单独删除。"))
        }
        .sheet(isPresented: $showAddLocalSheet) {
            LocalTrackPickerSheet(
                importId: youTubeImport.id,
                existingTrackIds: Set(localAdditions.map { $0.id })
            )
            .environment(importService)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            artwork
                .frame(width: 240, height: 240)
                .shadow(radius: 20)
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("PLAYLIST", "歌单"))
                    .font(.caption).fontWeight(.bold)
                    .foregroundStyle(BrandColors.textSecondary)
                    .tracking(1.5)

                Text(youTubeImport.title)
                    .font(.largeTitle).fontWeight(.bold)
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(2)

                Text(metadataLine)
                    .font(.subheadline)
                    .foregroundStyle(BrandColors.textSecondary)

                HStack(spacing: 12) {
                    Button { playAll() } label: {
                        Label(tr("Play", "播放"), systemImage: "play.fill")
                            .padding(.horizontal, 16).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandColors.magenta)
                    .disabled(allSnaps.isEmpty)

                    Button { shuffleAll() } label: {
                        Label(tr("Shuffle", "随机播放"), systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(allSnaps.isEmpty)

                    Button { showAddLocalSheet = true } label: {
                        Label(tr("Add Local", "添加本地"), systemImage: "plus")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        if let url = URL(string: youTubeImport.url) { NSWorkspace.shared.open(url) }
                    } label: {
                        Label(tr("Open in YT", "在 YT 中打开"), systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task {
                            syncing = true
                            _ = try? await importService.resync(importId: youTubeImport.id)
                            syncing = false
                        }
                    } label: {
                        if syncing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(tr("Resync", "重新同步"), systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(syncing)

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label(tr("Delete", "删除"), systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            }
            Spacer()
        }
    }

    /// 元数据:频道 • 曲目数 • 总时长。
    private var metadataLine: String {
        let count = allSnaps.count
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
                AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(first.youTubeId)/hqdefault.jpg")) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() }
                    else { placeholder }
                }
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
        VStack(spacing: 0) {
            // YT 条目
            ForEach(items, id: \.id) { item in
                SongObjectView(
                    title: item.title,
                    artist: item.artist,
                    durationLabel: item.durationMs > 0 ? formatMs(item.durationMs) : nil,
                    indexLabel: "\(item.order + 1)",
                    artwork: importItemArtwork(item),
                    isSelected: selectedRowID == item.id,
                    showsPlayButton: true,
                    onSelect: { selectedRowID = item.id },
                    onPlay: { playItem(item) },
                    onQueue: {
                        if let t = item.track { playback.queue.addToQueue(TrackSnapshot(from: t)) }
                    },
                    onInbox: {
                        if let t = item.track { inbox.add(TrackSnapshot(from: t), source: .youTubeImport) }
                    }
                )
                .trackContextMenu(snapshot: item.track.map { TrackSnapshot(from: $0) },
                                  track: item.track,
                                  onPlay: { playItem(item) })
            }
            // 本地附加
            ForEach(Array(localAdditions.enumerated()), id: \.element.id) { idx, track in
                SongObjectView(
                    title: track.title,
                    artist: track.artist,
                    durationLabel: formatMs(Int(track.durationSeconds * 1000)),
                    indexLabel: "\(items.count + idx + 1)",
                    artwork: ArtworkSource.localHash(track.localArtworkHash ?? track.album?.artworkHash),
                    isSelected: selectedRowID == track.id,
                    showsPlayButton: true,
                    showLocalBadge: true,
                    onSelect: { selectedRowID = track.id },
                    onPlay: {
                        let snap = TrackSnapshot(from: track)
                        playback.playTrack(snap, context: allSnaps, from: .import)
                    },
                    onQueue: { playback.queue.addToQueue(TrackSnapshot(from: track)) },
                    onInbox: { inbox.add(TrackSnapshot(from: track), source: .youTubeImport) }
                )
                .trackContextMenu(snapshot: TrackSnapshot(from: track),
                                  track: track,
                                  onPlay: {
                                      let snap = TrackSnapshot(from: track)
                                      playback.playTrack(snap, context: allSnaps, from: .import)
                                  })
            }

            // 本地附加管理区
            if !localAdditions.isEmpty {
                Divider().background(BrandColors.textSecondary.opacity(0.1))
                HStack {
                    Text(tr("Local additions (shown locally only, not synced back to YT)",
                            "本地附加(仅本地显示,不同步回 YT)"))
                        .font(.caption).fontWeight(.medium)
                        .foregroundStyle(BrandColors.green)
                    Spacer()
                }
                .padding(.horizontal, 4).padding(.top, 10)
                ForEach(localAdditions, id: \.id) { track in
                    HStack {
                        Image(systemName: "music.note").foregroundStyle(BrandColors.green)
                            .frame(width: 20)
                        Text(track.title).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
                        Spacer()
                        Button {
                            importService.removeLocalAddition(importId: youTubeImport.id, trackId: track.id)
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(BrandColors.textSecondary)
                            .help(tr("Remove local addition", "移除本地附加"))
                    }
                    .padding(.horizontal, 4).padding(.vertical, 4)
                }
            }
        }
    }

    private func playItem(_ item: YouTubeImportItem) {
        guard let t = item.track else { return }
        let snap = TrackSnapshot(from: t)
        let ctx = allSnaps
        guard let target = ctx.first(where: { $0.id == snap.id }) ?? ctx.first else { return }
        playback.playTrack(target, context: ctx, from: .import)
    }

    private func playAll() {
        guard let first = allSnaps.first else { return }
        playback.playTrack(first, context: allSnaps, from: .import)
    }

    private func shuffleAll() {
        guard !allSnaps.isEmpty else { return }
        let shuffled = allSnaps.shuffled()
        guard let first = shuffled.first else { return }
        playback.playTrack(first, context: shuffled, from: .import)
    }

    // MARK: - Gradient

    private func extractGradient() {
        // 从封面 URL 提取主色调(异步加载后用 NSImage)
        let urlStr = youTubeImport.artworkUrl
            ?? (items.first.map { "https://i.ytimg.com/vi/\($0.youTubeId)/hqdefault.jpg" })
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
        if let t = item.track {
            return ArtworkSource.resolve(for: TrackSnapshot(from: t))
        }
        if let url = URL(string: "https://i.ytimg.com/vi/\(item.youTubeId)/hqdefault.jpg") {
            return .remote(url)
        }
        return .placeholder
    }
}