import SwiftUI
import AppKit

struct ArtistDetailView: View {
    let artistName: String
    @Binding var selection: String?
    @Environment(LibraryService.self) private var library
    @Environment(PlaybackService.self) private var playback
    @Binding var selectedAlbum: Album?
    @State private var gradient: [Color] = [BrandColors.background, BrandColors.surface]

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: 4)
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

    private var albums: [Album] { library.albums(byArtist: artistName) }
    private var tracks: [Track] { library.tracks(byArtist: artistName) }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            ZStack {
                Circle().fill(BrandColors.surface).frame(width: 180, height: 180)
                Image(systemName: "person.2.fill").font(.system(size: 48))
                    .foregroundStyle(BrandColors.textSecondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(artistName).font(.largeTitle).fontWeight(.bold)
                    .foregroundStyle(BrandColors.textPrimary)
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