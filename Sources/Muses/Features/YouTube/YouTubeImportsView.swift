import SwiftUI
import SwiftData

/// YouTube playlist import management view.
///
/// Lists imported YouTube playlists. Remote inspection stays read-only until
/// the user opens a playlist and explicitly chooses Pull or Push.
struct YouTubeImportsView: View {
    @Environment(YouTubeImportService.self) private var importService
    @Query(sort: \YouTubeImport.importedAt, order: .reverse) private var imports: [YouTubeImport]

    @State private var showImportSheet = false
    @State private var importing = false
    @State private var error: String?
    /// True when embedded in YouTubeMusicView: hides the duplicate large title and navigationTitle.
    var embedded: Bool = false

    private var activeImports: [YouTubeImport] {
        imports.filter { $0.deletedAt == nil }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header row (when embedded, show only the import button — no duplicate title)
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

                if activeImports.isEmpty {
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
                        ForEach(activeImports, id: \.id) { imp in
                            YouTubeImportCard(imp: imp)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 24)
        }
        .background(BrandColors.background)
        .sheet(isPresented: $showImportSheet) {
            YouTubeImportSheet { url in
                importing = true
                error = nil
                Task {
                    do {
                        _ = try await importService.importPlaylist(url: url)
                    } catch let err {
                        error = err.localizedDescription
                    }
                    importing = false
                    showImportSheet = false
                }
            }
        }
    }
}

/// One YouTube import card: cover + title + metadata + action buttons + expandable items.
struct YouTubeImportCard: View {
    let imp: YouTubeImport
    @Environment(PlaybackService.self) private var playback
    @Environment(InboxService.self) private var inbox
    @Environment(YouTubePlaylistSyncService.self) private var playlistSync
    @State private var expanded = false
    @State private var syncing = false
    @State private var syncError: String?
    @State private var selectedItemID: UUID?

    private var items: [YouTubeImportItem] {
        (imp.items ?? []).sorted { $0.order < $1.order }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: cover + info + actions
            HStack(spacing: 14) {
                // Cover — opens the album detail on tap
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
                    // Action buttons
                    HStack(spacing: 8) {
                        Button {
                            Task { await checkRemote() }
                        } label: {
                            if syncing {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(tr("Check Remote", "检查远端"), systemImage: "arrow.down.to.line")
                            }
                        }
                        .buttonStyle(.bordered).disabled(syncing)

                        Button {
                            if let url = URL(string: imp.url) { NSWorkspace.shared.open(url) }
                        } label: { Label(tr("Open in YT", "在 YT 中打开"), systemImage: "arrow.up.right.square") }
                        .buttonStyle(.bordered)

                        Button(role: .destructive) {
                            deleteImport()
                        } label: { Label(tr("Delete", "删除"), systemImage: "trash") }
                        .buttonStyle(.bordered)

                        Button {
                            playAll()
                        } label: { Label(tr("Play", "播放"), systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).tint(BrandColors.magenta)
                    }
                    .padding(.top, 2)
                    if let syncError {
                        Text(syncError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
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
            .contextMenu { importContextMenu }

            // Expanded items
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
                            nowPlayingID: item.track?.id,
                            showsHoverPlay: true,
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

                }
            }
        }
        .background(BrandColors.surface)
        .cornerRadius(12)
    }

    @ViewBuilder
    private var importContextMenu: some View {
        Button(tr("Open Playlist", "打开歌单"), systemImage: "arrow.forward.circle") {
            NotificationCenter.default.post(name: .musesNavigateYouTubeImport, object: imp)
        }
        if !visibleSnaps.isEmpty {
            Button(tr("Play", "播放"), systemImage: "play.fill", action: playAll)
        }
        Button(tr("Check Remote", "检查远端"), systemImage: "arrow.down.to.line") {
            Task { await checkRemote() }
        }
        .disabled(syncing)
        if let url = URL(string: imp.url) {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label {
                    Text(tr("Open on YouTube", "在 YouTube 打开"))
                } icon: {
                    YouTubeMark(size: 12)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(tr("Open on YouTube", "在 YouTube 打开"))
        }
        Divider()
        Button(tr("Delete Import", "删除导入"), systemImage: "trash", role: .destructive) {
            deleteImport()
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
        items.compactMap(\.track)
            .filter { !$0.youTubeId.isEmpty }
            .map(TrackSnapshot.init(from:))
    }

    private func playAll() {
        guard let first = visibleSnaps.first else { return }
        playback.playTrack(first, context: visibleSnaps, from: .import)
    }

    private func checkRemote() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        syncError = nil
        do {
            _ = try await playlistSync.checkRemote(importID: imp.id)
        } catch {
            syncError = error.localizedDescription
        }
    }

    private func deleteImport() {
        syncError = nil
        do {
            try playlistSync.moveToRecentlyDeleted(importID: imp.id)
        } catch {
            syncError = error.localizedDescription
        }
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
        if let url = YouTubeThumbnail.url(videoId: item.youTubeId) {
            return .remote(url)
        }
        return .placeholder
    }
}
