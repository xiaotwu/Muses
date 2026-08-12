import SwiftUI
import AppKit

struct ArtistsView: View {
    @Binding var selectedArtist: Artist?
    @Environment(LibraryService.self) private var library
    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var searchTask: Task<Void, Never>?

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: 5)
    }

    var body: some View {
        let artists = filteredArtists()
        ScrollView {
            if artists.isEmpty {
                EmptyStateView(
                    icon: "person.2",
                    title: searchText.isEmpty ? "资料库中没有艺术家" : "无搜索结果")
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(artists, id: \.id) { artist in
                        ArtistCard(artist: artist)
                            .onTapGesture { selectedArtist = artist }
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("艺术家")
        .searchable(text: $searchText, prompt: "搜索艺术家")
        .onChange(of: searchText) { _, newValue in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                debouncedSearch = newValue
            }
        }
        .background(BrandColors.background)
    }

    private func filteredArtists() -> [Artist] {
        let all = library.allArtists()
        let q = debouncedSearch.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }
}

struct ArtistCard: View {
    let artist: Artist
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let art = artist.artworkHash.flatMap { ArtworkCache.default.path(forHash: $0) }
                .map { NSImage(byReferencing: $0) }
            ZStack {
                Circle().fill(BrandColors.surface).frame(width: 200, height: 200)
                if let img = art {
                    Image(nsImage: img).resizable().scaledToFill()
                        .frame(width: 200, height: 200).clipShape(Circle())
                } else {
                    Image(systemName: "person.2.fill").font(.largeTitle)
                        .foregroundStyle(BrandColors.textSecondary)
                }
            }
            Text(artist.name).font(.subheadline).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
            Text("\(artist.albums.count) 张专辑").font(.caption).foregroundStyle(BrandColors.textSecondary)
        }
    }
}