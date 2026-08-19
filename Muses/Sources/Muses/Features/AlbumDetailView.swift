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
    /// 批量已喜欢 id 集合,避免每行 `TrackRow` 单独 fetch。
    @State private var likedSet: Set<UUID> = []
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
        Group {
            if let h = album.artworkHash, let p = ArtworkCache.default.path(forHash: h) {
                Image(nsImage: NSImage(byReferencing: p)).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 12).fill(BrandColors.surface)
                    .overlay(Image(systemName: "music.note").font(.largeTitle))
            }
        }
        .clipped().cornerRadius(12)
    }

    private var trackList: some View {
        VStack(spacing: 0) {
            ForEach(sortedTracks(), id: \.id) { track in
                TrackRow(track: track, likedIDs: likedSet)
                    .onTapGesture { play(track) }
                    .trackContextMenu(snapshot: TrackSnapshot(from: track),
                                      track: track,
                                      playlists: allPlaylists,
                                      onPlay: { play(track) })
                    .padding(.vertical, 6)
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
        guard let h = album.artworkHash, let p = ArtworkCache.default.path(forHash: h),
              let img = NSImage(contentsOf: p) else { return }
        let colors = AlbumArtworkExtractor.dominantColors(img, count: 4)
        gradient = colors.map { Color(nsColor: $0) } + [BrandColors.background]
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

struct TrackRow: View {
    let track: Track
    var showHeart: Bool = true
    /// 父视图批量查询的已喜欢 id 集合;为 nil 时回退到单次 `isLiked(id:)`。
    var likedIDs: Set<UUID>? = nil
    @Environment(LibraryService.self) private var library
    var body: some View {
        let _ = library.likedRevision
        let _ = library.metadataRevision
        let liked = likedIDs?.contains(track.id) ?? library.isLiked(id: track.id)
        HStack {
            Text("\(track.trackNo ?? 0)").foregroundStyle(BrandColors.textSecondary)
                .frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading) {
                Text(track.title).foregroundStyle(BrandColors.textPrimary)
                Text(track.artist).font(.caption).foregroundStyle(BrandColors.textSecondary)
            }
            Spacer()
            if track.isLossless {
                Text("Hi-Res").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(BrandColors.green.opacity(0.2))
                    .foregroundStyle(BrandColors.green).cornerRadius(4)
            }
            if showHeart {
                Button { library.toggleLike(track) } label: {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.caption)
                }
                .foregroundStyle(liked ? BrandColors.magenta : BrandColors.textSecondary)
                .buttonStyle(.plain)
                .help(liked ? tr("Unlike", "取消收藏") : tr("Like", "收藏"))
            }
            Text(formatDuration(track.durationSeconds)).foregroundStyle(BrandColors.textSecondary)
        }
    }
    private func formatDuration(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}