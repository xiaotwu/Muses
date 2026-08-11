import SwiftUI
import AppKit
import SwiftData

struct LibraryView: View {
    @Binding var selection: SidebarSection
    @Binding var selectedAlbum: Album?
    @Environment(LibraryService.self) private var library
    @Environment(PlaybackService.self) private var playback

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
    var body: some View { Text("Liked").frame(maxWidth: .infinity, maxHeight: .infinity) }
}

struct SettingsPlaceholderView: View {
    var body: some View { Text("Settings").frame(maxWidth: .infinity, maxHeight: .infinity) }
}

// MARK: - Stubs (replaced by Task 11 / Task 12)
// These minimal stubs exist only so Task 10 compiles standalone.
// Task 11 replaces AlbumDetailView; Task 12 replaces PlayerBar.
struct AlbumDetailView: View {
    let album: Album
    var body: some View { Text(album.title).frame(maxWidth: .infinity, maxHeight: .infinity) }
}

struct PlayerBar: View {
    var body: some View { Color.clear.frame(height: 76) }
}