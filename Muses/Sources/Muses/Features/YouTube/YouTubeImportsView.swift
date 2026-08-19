import SwiftUI
import SwiftData

/// YouTube 歌单导入管理视图(spec §7.5)。
///
/// 列出所有已导入的 YouTube 歌单,支持重新同步、在 YT 中打开、删除、播放;
/// 可展开查看条目与本地附加区。顶部按钮弹出导入 sheet。
struct YouTubeImportsView: View {
    @Environment(YouTubeImportService.self) private var importService
    @Environment(PlaybackService.self) private var playback
    @Query(sort: \YouTubeImport.importedAt, order: .reverse) private var imports: [YouTubeImport]

    @State private var showImportSheet = false
    @State private var importing = false
    @State private var error: String?
    /// 嵌入到 YouTubeMusicView 时为 true:隐藏重复的大标题与 navigationTitle。
    var embedded: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 标题栏(嵌入时仅显示导入按钮,不重复标题)
                HStack {
                    if !embedded {
                        Text(tr("YouTube Imports", "YouTube 导入"))
                            .font(.largeTitle).fontWeight(.bold)
                            .foregroundStyle(BrandColors.textPrimary)
                    }
                    Spacer()
                    Button {
                        showImportSheet = true
                    } label: {
                        Label(tr("Import YouTube Playlist", "导入 YouTube 歌单"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandColors.magenta)
                    .disabled(importing)
                }
                .padding(.horizontal, 20)

                if let err = error {
                    Text(err).font(.callout).foregroundStyle(.red)
                        .padding(.horizontal, 20)
                }

                if imports.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 48))
                            .foregroundStyle(BrandColors.textSecondary.opacity(0.5))
                        Text(tr("No YouTube playlists imported yet", "尚未导入任何 YouTube 歌单"))
                            .font(.title3).foregroundStyle(BrandColors.textSecondary)
                        Text(tr("Click the button at the top-right, paste a YouTube playlist link to start importing", "点击右上角按钮,粘贴 YouTube 歌单链接开始导入"))
                            .font(.callout).foregroundStyle(BrandColors.textSecondary.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 80)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(imports, id: \.id) { imp in
                            YouTubeImportCard(imp: imp)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 24)
        }
        .modifier(ConditionalNavTitle(title: tr("YouTube Imports", "YouTube 导入"), enabled: !embedded))
        .background(BrandColors.background)
        .sheet(isPresented: $showImportSheet) {
            YouTubeImportSheet { url in
                importing = true
                error = nil
                Task {
                    do {
                        _ = try await importService.importPlaylist(url: url)
                    } catch let err {
                        error = "\(err)"
                    }
                    importing = false
                    showImportSheet = false
                }
            }
        }
    }
}

/// 单条 YouTube 导入卡片:封面 + 标题 + 元信息 + 操作按钮 + 可展开条目。
struct YouTubeImportCard: View {
    let imp: YouTubeImport
    @Environment(YouTubeImportService.self) private var importService
    @Environment(PlaybackService.self) private var playback
    @Environment(InboxService.self) private var inbox
    @State private var expanded = false
    @State private var syncing = false
    @State private var showAddLocalSheet = false
    @State private var selectedItemID: UUID?

    private var items: [YouTubeImportItem] {
        (imp.items ?? []).sorted { $0.order < $1.order }
    }
    private var localAdditions: [Track] {
        imp.localAdditions ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部:封面 + 信息 + 操作
            HStack(spacing: 14) {
                // 封面 — 点击进入专辑详情
                Button {
                    NotificationCenter.default.post(name: .musesNavigateYouTubeImport, object: imp)
                } label: {
                    artworkView
                        .frame(width: 80, height: 80)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    Text(imp.title).font(.headline).foregroundStyle(BrandColors.textPrimary)
                        .lineLimit(1)
                        .onTapGesture {
                            NotificationCenter.default.post(name: .musesNavigateYouTubeImport, object: imp)
                        }
                    HStack(spacing: 8) {
                        Text(imp.channel).font(.caption).foregroundStyle(BrandColors.textSecondary)
                        Text("·").foregroundStyle(BrandColors.textSecondary)
                        Text("\(items.count) \(tr("songs", "首"))").font(.caption).foregroundStyle(BrandColors.textSecondary)
                        if let synced = imp.lastSyncedAt {
                            Text("·").foregroundStyle(BrandColors.textSecondary)
                            Text("\(tr("Last synced", "上次同步")) \(relativeDate(synced))").font(.caption)
                                .foregroundStyle(BrandColors.textSecondary)
                        }
                    }
                    // 操作按钮
                    HStack(spacing: 8) {
                        Button {
                            Task {
                                syncing = true
                                _ = try? await importService.resync(importId: imp.id)
                                syncing = false
                            }
                        } label: {
                            if syncing {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(tr("Resync", "重新同步"), systemImage: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.bordered).disabled(syncing)

                        Button {
                            if let url = URL(string: imp.url) { NSWorkspace.shared.open(url) }
                        } label: { Label(tr("Open in YT", "在 YT 中打开"), systemImage: "arrow.up.right.square") }
                        .buttonStyle(.bordered)

                        Button(role: .destructive) {
                            importService.deleteImport(importId: imp.id)
                        } label: { Label(tr("Delete", "删除"), systemImage: "trash") }
                        .buttonStyle(.bordered)

                        Button {
                            playAll()
                        } label: { Label(tr("Play", "播放"), systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).tint(BrandColors.magenta)
                    }
                    .padding(.top, 2)
                }

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(BrandColors.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            // 展开条目
            if expanded {
                Divider().background(BrandColors.textSecondary.opacity(0.1))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items, id: \.id) { item in
                        SongObjectView(
                            title: item.title,
                            artist: item.artist,
                            durationLabel: formatImportDuration(item.durationMs),
                            indexLabel: "\(item.order + 1)",
                            artwork: importItemArtwork(item),
                            isSelected: selectedItemID == item.id,
                            showsPlayButton: true,
                            onSelect: { selectedItemID = item.id },
                            onPlay: {
                                if let t = item.track {
                                    let snap = TrackSnapshot(from: t)
                                    playback.playTrack(snap, context: visibleSnaps, from: .import)
                                }
                            },
                            onQueue: {
                                if let t = item.track {
                                    playback.queue.addToQueue(TrackSnapshot(from: t))
                                }
                            },
                            onInbox: {
                                if let t = item.track {
                                    inbox.add(TrackSnapshot(from: t), source: .youTubeImport)
                                }
                            }
                        )
                        .trackContextMenu(snapshot: item.track.map { TrackSnapshot(from: $0) },
                                          track: item.track,
                                          onPlay: {
                                              if let t = item.track {
                                                  let snap = TrackSnapshot(from: t)
                                                  playback.playTrack(snap, context: visibleSnaps, from: .import)
                                              }
                                          })
                    }

                    // 本地附加区
                    Divider().background(BrandColors.textSecondary.opacity(0.1))
                    HStack {
                        Text(tr("Local additions (shown locally only, not synced back to YT)", "本地附加(仅本地显示,不同步回 YT)"))
                            .font(.caption).fontWeight(.medium)
                            .foregroundStyle(BrandColors.green)
                        Spacer()
                        Button {
                            showAddLocalSheet = true
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(BrandColors.green)
                        .help(tr("Add local tracks to this import", "添加本地曲目到此导入"))
                    }
                    .padding(.horizontal, 12).padding(.top, 8)

                    if localAdditions.isEmpty {
                        Text(tr("No local additions yet, tap + to add", "暂无本地附加,点 + 添加"))
                            .font(.caption2)
                            .foregroundStyle(BrandColors.textSecondary)
                            .padding(.horizontal, 12).padding(.bottom, 8)
                    } else {
                        ForEach(localAdditions, id: \.id) { track in
                            HStack {
                                Image(systemName: "music.note").foregroundStyle(BrandColors.green)
                                    .frame(width: 20)
                                Text(track.title).foregroundStyle(BrandColors.textPrimary)
                                Text(tr("Local", "本地")).font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(BrandColors.green.opacity(0.2))
                                    .cornerRadius(4)
                                Spacer()
                                Button {
                                    importService.removeLocalAddition(importId: imp.id, trackId: track.id)
                                } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(BrandColors.textSecondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                        }
                    }
                }
            }
        }
        .background(BrandColors.surface)
        .cornerRadius(12)
        .sheet(isPresented: $showAddLocalSheet) {
            LocalTrackPickerSheet(
                importId: imp.id,
                existingTrackIds: Set(localAdditions.map { $0.id })
            )
            .environment(importService)
        }
    }

    private var artworkView: some View {
        Group {
            if let urlStr = imp.artworkUrl, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() }
                    else { placeholder }
                }
            } else {
                placeholder
            }
        }
    }
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8).fill(BrandColors.surface)
            .overlay(Image(systemName: "music.note.list")
                .font(.title2).foregroundStyle(BrandColors.textSecondary.opacity(0.5)))
    }

    private var visibleSnaps: [TrackSnapshot] {
        items.compactMap { $0.track }.map { TrackSnapshot(from: $0) }
    }

    private func playAll() {
        guard let first = visibleSnaps.first else { return }
        playback.playTrack(first, context: visibleSnaps, from: .import)
    }

    private func relativeDate(_ d: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: d, relativeTo: .now)
    }

    private func formatImportDuration(_ ms: Int) -> String {
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

/// 本地曲目选择 sheet:从本地 Track(source == .local)中多选,
/// 确认后批量调 `addLocalAddition`。
struct LocalTrackPickerSheet: View {
    let importId: UUID
    let existingTrackIds: Set<UUID>
    @Environment(YouTubeImportService.self) private var importService
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Track> { $0.sourceRaw == "local" },
           sort: \Track.title)
    private var localTracks: [Track]

    @State private var selectedIds: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            Text(tr("Add local tracks to this import", "添加本地曲目到此导入"))
                .font(.headline)
                .foregroundStyle(BrandColors.textPrimary)
                .padding(.top, 16).padding(.bottom, 12)

            if localTracks.isEmpty {
                Text(tr("No local tracks in library", "资料库中暂无本地曲目"))
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(localTracks, id: \.id) { track in
                        HStack {
                            Image(systemName: selectedIds.contains(track.id) || existingTrackIds.contains(track.id)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(BrandColors.magenta)
                            VStack(alignment: .leading) {
                                Text(track.title).foregroundStyle(BrandColors.textPrimary)
                                Text(track.artist).font(.caption).foregroundStyle(BrandColors.textSecondary)
                            }
                            Spacer()
                            if existingTrackIds.contains(track.id) {
                                Text(tr("Added", "已添加")).font(.caption2).foregroundStyle(BrandColors.textSecondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !existingTrackIds.contains(track.id) else { return }
                            if selectedIds.contains(track.id) {
                                selectedIds.remove(track.id)
                            } else {
                                selectedIds.insert(track.id)
                            }
                        }
                    }
                }
            }

            HStack {
                Button(tr("Cancel", "取消")) { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button(tr("Add \(selectedIds.count) songs", "添加 \(selectedIds.count) 首")) {
                    for id in selectedIds {
                        importService.addLocalAddition(importId: importId, trackId: id)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColors.magenta)
                .disabled(selectedIds.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 420, height: 480)
        .background(.ultraThinMaterial)
    }
}

/// 仅在 `enabled` 时应用 `.navigationTitle`,嵌入到合并视图时跳过。
private struct ConditionalNavTitle: ViewModifier {
    let title: String
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.navigationTitle(title) } else { content }
    }
}