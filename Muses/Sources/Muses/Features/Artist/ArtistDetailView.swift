import SwiftUI
import AppKit

struct ArtistDetailView: View {
    let artist: Artist
    @Binding var selection: Artist?
    @Environment(LibraryService.self) private var library
    @Environment(PlaybackService.self) private var playback
    @Binding var selectedAlbum: Album?
    @State private var gradient: [Color] = [BrandColors.background, BrandColors.surface]

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: 4)
    }

    /// 从 Artist 关系派生的专辑(按标题排序),在 fresh context 中 re-fetch 以获得有效对象。
    private var albums: [Album] {
        library.albums(byArtist: artist)
    }
    /// 从 Artist 关系派生的曲目(按专辑+曲目号排序)。
    private var tracks: [Track] {
        library.tracks(byArtist: artist)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: gradient, startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if !albums.isEmpty {
                        albumSection
                    }
                    if !tracks.isEmpty {
                        trackSection
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { selection = nil } label: { Image(systemName: "chevron.backward") }
            }
        }
        .onAppear { extractGradient() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            let art = artist.artworkHash.flatMap { ArtworkCache.default.path(forHash: $0) }
                .map { NSImage(byReferencing: $0) }
            ZStack {
                Circle().fill(BrandColors.surface).frame(width: 180, height: 180)
                if let img = art {
                    Image(nsImage: img).resizable().scaledToFill()
                        .frame(width: 180, height: 180).clipShape(Circle())
                } else {
                    Image(systemName: "person.2.fill").font(.system(size: 48))
                        .foregroundStyle(BrandColors.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(artist.name).font(.largeTitle).fontWeight(.bold)
                    .foregroundStyle(BrandColors.textPrimary)
                if let genre = artist.primaryGenre {
                    Text(genre).font(.caption).foregroundStyle(BrandColors.cyan)
                }
                Text("\(albums.count) 张专辑 · \(tracks.count) 首歌曲")
                    .font(.title3).foregroundStyle(BrandColors.textSecondary)
                Button { playAll() } label: {
                    Label("Play", systemImage: "play.fill").padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColors.magenta)
            }
            Spacer()
        }
    }

    private var albumSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("专辑").font(.headline).foregroundStyle(BrandColors.textPrimary)
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(albums, id: \.id) { album in
                    AlbumCard(album: album)
                        .onTapGesture { selectedAlbum = album }
                }
            }
        }
    }

    private var trackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("歌曲").font(.headline).foregroundStyle(BrandColors.textPrimary)
            VStack(spacing: 0) {
                ForEach(tracks, id: \.id) { track in
                    TrackRow(track: track, showHeart: true)
                        .onTapGesture { play(track) }
                        .padding(.vertical, 6)
                }
            }
        }
    }

    private func play(_ track: Track) {
        let snaps = tracks.map { TrackSnapshot(from: $0) }
        guard let snap = snaps.first(where: { $0.id == track.id }) else { return }
        playback.playTrack(snap, context: snaps, from: .artist)
    }

    private func playAll() {
        guard let first = tracks.first else { return }
        play(first)
    }

    private func extractGradient() {
        // 从第一张专辑封面提取渐变色
        guard let album = albums.first,
              let h = album.artworkHash, let p = ArtworkCache.default.path(forHash: h),
              let img = NSImage(contentsOf: p) else { return }
        let colors = AlbumArtworkExtractor.dominantColors(img, count: 3)
        gradient = colors.map { Color(nsColor: $0) } + [BrandColors.background]
    }
}