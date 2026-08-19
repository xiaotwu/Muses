import SwiftUI
import AppKit
import SwiftData

struct AlbumDetailView: View {
    let album: Album
    @Binding var selection: Album?
    @Environment(PlaybackService.self) private var playback
    @Environment(LibraryService.self) private var library
    @Environment(NotesService.self) private var notes
    @Query(sort: \Playlist.name) private var allPlaylists: [Playlist]
    @State private var gradient: [Color] = [BrandColors.background, BrandColors.surface]
    @State private var gradientTask: Task<Void, Never>?
    /// 批量已喜欢 id 集合,避免每行单独 fetch。
    @State private var likedSet: Set<UUID> = []
    @State private var selectedTrackID: UUID?
    @State private var showAlbumNotes = false

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
                Button { selection = nil } label: { Image(systemName: "chevron.backward") }
            }
        }
        .onAppear { extractGradient(); refreshLikedSet() }
        .onDisappear { gradientTask?.cancel(); gradientTask = nil }
        .onChange(of: library.likedRevision) { _, _ in refreshLikedSet() }
        .sheet(isPresented: $showAlbumNotes) {
            AlbumNotesSheet(album: album)
        }
    }

    private func refreshLikedSet() {
        likedSet = library.likedIDs(for: sortedTracks().map(\.id))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            artwork
                .frame(width: 240, height: 240)
                .shadow(radius: 20)
            VStack(alignment: .leading, spacing: 8) {
                // 小标签:ALBUM
                Text(tr("ALBUM", "专辑"))
                    .font(.caption).fontWeight(.bold)
                    .foregroundStyle(BrandColors.textSecondary)
                    .tracking(1.5)

                Text(album.title)
                    .font(.largeTitle).fontWeight(.bold)
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(2)

                // 元数据行:艺术家 • 年份 • 曲目数 • 总时长
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

                    // 钉选按钮
                    let pinned = library.isPinned(album)
                    Button { library.togglePin(album) } label: {
                        Image(systemName: pinned ? "pin.fill" : "pin")
                    }
                    .buttonStyle(.bordered)
                    .help(pinned ? tr("Unpin", "取消钉选") : tr("Pin", "钉选"))

                    // 专辑笔记(Phase 21 §10.7)
                    let hasNote = notes.note(forAlbum: album.id) != nil
                    Button { showAlbumNotes = true } label: {
                        Image(systemName: hasNote ? "note.text" : "note.text.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .help(tr("Album Note", "专辑笔记"))
                }
                .padding(.top, 4)
            }
            Spacer()
        }
    }

    /// 元数据:艺术家 • 年份 • 曲目数 • 总时长。
    private var metadataLine: String {
        let tracks = sortedTracks()
        var parts: [String] = [album.albumArtist]
        if let year = album.year { parts.append(String(year)) }
        let count = tracks.count
        parts.append("\(count) \(count == 1 ? tr("song", "首") : tr("songs", "首"))")
        let totalSec = tracks.reduce(0.0) { $0 + $1.durationSeconds }
        parts.append(formatDuration(totalSec))
        return parts.joined(separator: " • ")
    }

    private var artwork: some View {
        ArtworkView(
            source: ArtworkSource.localHash(album.artworkHash),
            cornerRadius: 12,
            glyphSize: 32,
            targetSize: 240
        )
    }

    private var trackList: some View {
        VStack(spacing: 0) {
            ForEach(sortedTracks(), id: \.id) { track in
                SongObjectView(
                    title: track.title,
                    artist: track.artist,
                    durationLabel: formatDuration(track.durationSeconds),
                    indexLabel: "\(track.trackNo ?? 0)",
                    artwork: ArtworkSource.localHash(track.localArtworkHash ?? track.album?.artworkHash),
                    isSelected: selectedTrackID == track.id,
                    isLossless: track.isLossless,
                    isLiked: likedSet.contains(track.id),
                    onToggleLike: { library.toggleLike(track) },
                    onSelect: { selectedTrackID = track.id; play(track) },
                    onPlay: { play(track) }
                )
                .trackContextMenu(snapshot: TrackSnapshot(from: track),
                                  track: track,
                                  playlists: allPlaylists,
                                  onPlay: { play(track) })
            }
        }
    }

    private func sortedTracks() -> [Track] {
        album.tracks.sorted { (a, b) in
            (a.discNo ?? 0, a.trackNo ?? 0) < (b.discNo ?? 0, b.trackNo ?? 0)
        }
    }

    private func play(_ track: Track) {
        let ctx = sortedTracks().map { TrackSnapshot(from: $0) }
        guard let snap = ctx.first(where: { $0.id == track.id }) else { return }
        playback.playTrack(snap, context: ctx, from: .album)
    }

    private func playAll() {
        guard let first = sortedTracks().first else { return }
        play(first)
    }

    private func extractGradient() {
        gradientTask?.cancel()
        let source = ArtworkSource.localHash(album.artworkHash)
        guard case .localFile = source else { return }
        let expectedID = album.id
        gradientTask = Task { @MainActor in
            let img = await Task.detached(priority: .userInitiated) {
                source.loadNSImage()
            }.value
            guard !Task.isCancelled, album.id == expectedID, let img else { return }
            let colors = AlbumArtworkExtractor.dominantColors(img, count: 4)
            guard !Task.isCancelled else { return }
            gradient = colors.map { Color(nsColor: $0) } + [BrandColors.background]
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