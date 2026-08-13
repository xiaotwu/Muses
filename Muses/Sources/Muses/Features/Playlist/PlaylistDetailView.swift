import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AppKit

/// 歌单详情页:展示曲目列表 + 拖拽排序 + 删除 + 播放 + M3U 导入/导出。
struct PlaylistDetailView: View {
    let playlist: Playlist
    @Binding var selectedPlaylist: Playlist?
    @Environment(PlaylistService.self) private var playlistService
    @Environment(PlaybackService.self) private var playback
    @State private var showAddTrackSheet = false
    @State private var showM3UImporter = false

    private var sortedItems: [PlaylistItem] {
        (playlist.items ?? []).sorted { $0.order < $1.order }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 头部
            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(BrandColors.surface)
                    .frame(width: 120, height: 120)
                    .overlay(
                        Image(systemName: "music.note.list")
                            .font(.largeTitle)
                            .foregroundStyle(BrandColors.cyan)
                    )

                VStack(alignment: .leading, spacing: 8) {
                    Text(playlist.name).font(.largeTitle).fontWeight(.bold)
                        .foregroundStyle(BrandColors.textPrimary)
                    Text("\(sortedItems.count) \(tr("songs", "首"))")
                        .font(.caption).foregroundStyle(BrandColors.textSecondary)

                    HStack(spacing: 12) {
                        Button {
                            playAll()
                        } label: {
                            Label(tr("Play All", "播放全部"), systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(BrandColors.magenta)
                        .disabled(sortedItems.isEmpty)

                        Button {
                            showAddTrackSheet = true
                        } label: {
                            Label(tr("Add Tracks", "添加曲目"), systemImage: "plus")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            showM3UImporter = true
                        } label: {
                            Label(tr("Import M3U", "导入 M3U"), systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            exportM3U()
                        } label: {
                            Label(tr("Export M3U", "导出 M3U"), systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .disabled(sortedItems.isEmpty)
                    }
                }
                Spacer()
            }
            .padding(20)

            // 曲目列表
            if sortedItems.isEmpty {
                EmptyStateView(icon: "music.note.list", title: tr("Playlist is empty", "歌单为空"),
                               subtitle: tr("Tap \"Add Tracks\" to import songs", "点击「添加曲目」导入歌曲"))
            } else {
                List {
                    ForEach(sortedItems, id: \.id) { item in
                        PlaylistTrackRow(item: item, onRemove: { removeItem(item) })
                    }
                    .onMove { indices, destination in
                        guard let from = indices.first else { return }
                        playlistService.moveItem(in: playlist, from: from,
                                                 to: destination > from ? destination - 1 : destination)
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(BrandColors.background)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { selectedPlaylist = nil } label: { Image(systemName: "chevron.left") }
            }
        }
        .sheet(isPresented: $showAddTrackSheet) {
            AddToPlaylistSheet(playlist: playlist)
                .environment(playlistService)
        }
        .fileImporter(isPresented: $showM3UImporter,
                      allowedContentTypes: [.text],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        _ = playlistService.importM3U(playlist, from: url)
                    }
                }
            case .failure: break
            }
        }
    }

    private func playAll() {
        let snaps = sortedItems.compactMap { item -> TrackSnapshot? in
            guard let track = item.track else { return nil }
            return TrackSnapshot(from: track)
        }
        guard let first = snaps.first else { return }
        playback.playTrack(first, context: snaps, from: .playlist)
    }

    private func removeItem(_ item: PlaylistItem) {
        playlistService.removeItem(item)
    }

    private func exportM3U() {
        let panel = NSSavePanel()
        panel.title = tr("Export M3U", "导出 M3U")
        panel.allowedContentTypes = [.text]
        panel.nameFieldStringValue = "\(playlist.name).m3u"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        playlistService.exportM3U(playlist, to: url)
    }
}

/// 歌单内曲目行。
struct PlaylistTrackRow: View {
    let item: PlaylistItem
    let onRemove: () -> Void
    @Environment(PlaybackService.self) private var playback

    var body: some View {
        HStack(spacing: 12) {
            if let track = item.track {
                Button {
                    let snap = TrackSnapshot(from: track)
                    playback.playTrack(snap, context: [snap], from: .playlist)
                } label: {
                    Image(systemName: "play.fill")
                        .foregroundStyle(BrandColors.magenta)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading) {
                    Text(track.title).foregroundStyle(BrandColors.textPrimary)
                    Text(track.artist).font(.caption).foregroundStyle(BrandColors.textSecondary)
                }
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(BrandColors.textSecondary)
                Text(tr("(Track deleted)", "(曲目已删除)")).foregroundStyle(BrandColors.textSecondary)
            }
            Spacer()
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(BrandColors.textSecondary)
        }
        .padding(.vertical, 4)
    }
}

/// 向歌单添加曲目的 sheet(复用本地 Track 列表选择模式)。
struct AddToPlaylistSheet: View {
    let playlist: Playlist
    @Environment(PlaylistService.self) private var playlistService
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Track> { $0.sourceRaw == "local" },
           sort: \Track.title)
    private var localTracks: [Track]
    @State private var selectedIds: Set<UUID> = []

    private var existingTrackIds: Set<UUID> {
        Set((playlist.items ?? []).compactMap { $0.track?.id })
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(tr("Add tracks to \"\(playlist.name)\"", "添加曲目到「\(playlist.name)」"))
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
                                Text(tr("Already in playlist", "已在歌单")).font(.caption2).foregroundStyle(BrandColors.textSecondary)
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
                    for track in localTracks where selectedIds.contains(track.id) {
                        playlistService.addTrack(playlist, track: track)
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