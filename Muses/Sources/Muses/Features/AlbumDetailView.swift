import SwiftUI
import AppKit

struct AlbumDetailView: View {
    let album: Album
    @Binding var selection: Album?
    @Environment(PlaybackService.self) private var playback
    @State private var gradient: [Color] = [BrandColors.background, BrandColors.surface]

    var body: some View {
        ZStack {
            LinearGradient(colors: gradient, startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    trackList
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
            artwork
                .frame(width: 220, height: 220)
                .shadow(radius: 12)
            VStack(alignment: .leading, spacing: 8) {
                Text(album.title).font(.largeTitle).fontWeight(.bold).foregroundStyle(BrandColors.textPrimary)
                Text(album.albumArtist).font(.title3).foregroundStyle(BrandColors.textSecondary)
                Button { playAll() } label: {
                    Label("Play", systemImage: "play.fill").padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColors.magenta)
            }
            Spacer()
        }
    }

    private var artwork: some View {
        Group {
            if let h = album.artworkHash, let p = ArtworkCache.default.path(forHash: h) {
                Image(nsImage: NSImage(byReferencing: p)).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 8).fill(BrandColors.surface)
                    .overlay(Image(systemName: "music.note").font(.largeTitle))
            }
        }
        .clipped().cornerRadius(8)
    }

    private var trackList: some View {
        VStack(spacing: 0) {
            ForEach(sortedTracks(), id: \.id) { track in
                TrackRow(track: track)
                    .onTapGesture { play(track) }
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
        let colors = AlbumArtworkExtractor.dominantColors(img, count: 3)
        gradient = colors.map { Color(nsColor: $0) } + [BrandColors.background]
    }
}

struct TrackRow: View {
    let track: Track
    var body: some View {
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
            Text(formatDuration(track.durationSeconds)).foregroundStyle(BrandColors.textSecondary)
        }
    }
    private func formatDuration(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}
