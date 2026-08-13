import SwiftUI

/// 最近添加页:按 addedAt 降序展示专辑。
struct RecentlyView: View {
    @Binding var selection: SidebarSection
    @Binding var selectedAlbum: Album?
    @Environment(LibraryService.self) private var library

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: 4)
    }

    var body: some View {
        ScrollView {
            let albums = library.allAlbums().sorted { a, b in
                // 按专辑中最新曲目的 addedAt 排序(无曲目则用最早)
                let aDate = a.tracks.map(\.addedAt).max() ?? .distantPast
                let bDate = b.tracks.map(\.addedAt).max() ?? .distantPast
                return aDate > bDate
            }
            if albums.isEmpty {
                EmptyStateView(
                    icon: "clock",
                    title: tr("No Albums", "暂无专辑"),
                    subtitle: tr("Import music to see recently added albums",
                                 "导入音乐后这里会显示最近添加的专辑")
                )
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(albums.prefix(50), id: \.id) { album in
                        AlbumCard(album: album)
                            .onTapGesture { selectedAlbum = album }
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle(tr("Recently", "最近"))
        .background(BrandColors.background)
    }
}