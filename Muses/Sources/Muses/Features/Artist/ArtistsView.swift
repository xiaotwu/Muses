import SwiftUI
import AppKit

struct ArtistsView: View {
    @Binding var selectedArtist: String?
    @Environment(LibraryService.self) private var library
    @State private var searchText = ""

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: 5)
    }

    var body: some View {
        let artists = filteredArtists()
        ScrollView {
            if artists.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.2").font(.system(size: 48))
                        .foregroundStyle(BrandColors.textSecondary)
                    Text(searchText.isEmpty ? "资料库中没有艺术家" : "无搜索结果")
                        .font(.title3).foregroundStyle(BrandColors.textPrimary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 80)
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(artists, id: \.self) { name in
                        ArtistCard(name: name, albumCount: library.albums(byArtist: name).count)
                            .onTapGesture { selectedArtist = name }
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("艺术家")
        .searchable(text: $searchText, prompt: "搜索艺术家")
        .background(BrandColors.background)
    }

    private func filteredArtists() -> [String] {
        let all = library.allArtists()
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(q) }
    }
}

struct ArtistCard: View {
    let name: String
    let albumCount: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Circle().fill(BrandColors.surface).frame(width: 200, height: 200)
                Image(systemName: "person.2.fill").font(.largeTitle)
                    .foregroundStyle(BrandColors.textSecondary)
            }
            Text(name).font(.subheadline).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
            Text("\(albumCount) 张专辑").font(.caption).foregroundStyle(BrandColors.textSecondary)
        }
    }
}