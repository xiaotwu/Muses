import SwiftUI
import AppKit
import SwiftData

struct LibraryView: View {
    @Binding var selection: SidebarSection
    @Binding var selectedAlbum: Album?
    @Environment(LibraryService.self) private var library

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: 5)
    }

    var body: some View {
        ScrollView {
            let progress = library.scanProgress
            if progress.total > 0, progress.scanned < progress.total {
                ProgressView(value: Double(progress.scanned), total: Double(progress.total))
                    .padding()
            }
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(library.allAlbums(), id: \.id) { album in
                    AlbumCard(album: album)
                        .onTapGesture { selectedAlbum = album }
                }
            }
            .padding(20)
        }
        .navigationTitle("Albums")
        .background(BrandColors.background)
    }
}

struct AlbumCard: View {
    let album: Album
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let art = album.artworkHash.flatMap { ArtworkCache.default.path(forHash: $0) }
                .map { NSImage(byReferencing: $0) }
            if let img = art {
                Image(nsImage: img).resizable().scaledToFill()
                    .frame(width: 200, height: 200).clipped().cornerRadius(8)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(BrandColors.surface)
                    .frame(width: 200, height: 200).overlay(Image(systemName: "music.note"))
            }
            Text(album.title).font(.subheadline).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
            Text(album.albumArtist).font(.caption).foregroundStyle(BrandColors.textSecondary).lineLimit(1)
        }
    }
}

struct SongsListView: View {
    @Environment(LibraryService.self) private var library
    var body: some View {
        let tracks = library.allTracks()
        List(tracks, id: \.id) { t in
            HStack {
                Text(t.title); Spacer(); Text(format(t.durationSeconds))
            }
        }
        .navigationTitle("Songs")
    }
    private func format(_ s: Double) -> String {
        let m = Int(s) / 60, sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }
}

struct LikedView: View {
    @Environment(LibraryService.self) private var library
    @Environment(PlaybackService.self) private var playback
    @Query(filter: #Predicate<Track> { $0.liked == true },
           sort: \Track.addedAt, order: .reverse)
    private var tracks: [Track]
    var body: some View {
        if tracks.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "heart").font(.system(size: 48))
                    .foregroundStyle(BrandColors.textSecondary)
                Text("还没有收藏的歌曲").font(.title3).foregroundStyle(BrandColors.textPrimary)
                Text("点击歌曲旁的 ❤️ 收藏").font(.subheadline)
                    .foregroundStyle(BrandColors.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 80)
            .navigationTitle("Liked")
        } else {
            List {
                ForEach(tracks, id: \.id) { track in
                    TrackRow(track: track, showHeart: true)
                        .onTapGesture { play(track) }
                        .padding(.vertical, 4)
                }
            }
            .navigationTitle("Liked")
            .safeAreaInset(edge: .bottom) {
                Button { playAll() } label: {
                    Label("播放全部", systemImage: "play.fill")
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColors.magenta)
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
    }
    private func play(_ track: Track) {
        let snaps = tracks.map { TrackSnapshot(from: $0) }
        guard let snap = snaps.first(where: { $0.id == track.id }) else { return }
        playback.playTrack(snap, context: snaps, from: .songs)
    }
    private func playAll() {
        guard let first = tracks.first else { return }
        play(first)
    }
}

struct SettingsPlaceholderView: View {
    var body: some View { Text("Settings").frame(maxWidth: .infinity, maxHeight: .infinity) }
}
