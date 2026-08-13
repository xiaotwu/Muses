import SwiftUI
import AppKit

/// 首页:Hero 动态封面 + 最近添加 + 钉选 + 全部专辑。
struct HomeView: View {
    @Binding var selection: SidebarSection
    @Binding var selectedAlbum: Album?
    @Environment(LibraryService.self) private var library
    @Environment(PlaybackService.self) private var playback
    @State private var heroGradient: [Color] = [BrandColors.background, BrandColors.surface]

    private var albums: [Album] { library.allAlbums() }

    /// Hero 专辑:优先选最近播放的,否则最近添加的,否则第一个。
    private var heroAlbum: Album? {
        library.mostRecentlyPlayedAlbum() ?? albums.first
    }

    /// 最近添加的专辑(按曲目 addedAt 降序,前 20)。
    private var recentlyAdded: [Album] {
        albums.sorted { a, b in
            let aDate = a.tracks.map(\.addedAt).max() ?? .distantPast
            let bDate = b.tracks.map(\.addedAt).max() ?? .distantPast
            return aDate > bDate
        }.prefix(20).map { $0 }
    }

    /// 钉选专辑。
    private var pinnedAlbums: [Album] { library.pinnedAlbums() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Hero
                if let hero = heroAlbum {
                    heroSection(hero)
                }

                // 最近添加
                if !recentlyAdded.isEmpty {
                    horizontalSection(
                        title: tr("Recently Added", "最近添加"),
                        albums: recentlyAdded
                    )
                }

                // 钉选
                if !pinnedAlbums.isEmpty {
                    horizontalSection(
                        title: tr("Pinned", "钉选"),
                        albums: pinnedAlbums
                    )
                }

                // 全部专辑
                if !albums.isEmpty {
                    allAlbumsSection
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 100)
        }
        .background(
            LinearGradient(colors: heroGradient,
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.4), value: heroAlbum?.id)
        )
        .onAppear { updateGradient() }
        .onChange(of: heroAlbum?.id) { _, _ in updateGradient() }
    }

    // MARK: - Hero

    private func heroSection(_ album: Album) -> some View {
        HStack(spacing: 24) {
            // 大封面
            let art = album.artworkHash.flatMap { ArtworkCache.default.path(forHash: $0) }
                .map { NSImage(byReferencing: $0) }
            if let img = art {
                Image(nsImage: img).resizable().scaledToFill()
                    .frame(width: 200, height: 200)
                    .clipped().cornerRadius(12)
                    .shadow(radius: 20)
            } else {
                RoundedRectangle(cornerRadius: 12).fill(BrandColors.surface)
                    .frame(width: 200, height: 200)
                    .overlay(Image(systemName: "music.note").font(.largeTitle))
                    .shadow(radius: 20)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(tr("FEATURED", "推荐"))
                    .font(.caption).fontWeight(.bold)
                    .foregroundStyle(BrandColors.textSecondary)
                    .tracking(1.5)
                Text(album.title)
                    .font(.largeTitle).fontWeight(.bold)
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(2)
                Text(album.albumArtist)
                    .font(.title3)
                    .foregroundStyle(BrandColors.textSecondary)
                if let year = album.year {
                    Text(String(year))
                        .font(.subheadline)
                        .foregroundStyle(BrandColors.textSecondary)
                }
                Button {
                    playAlbum(album)
                } label: {
                    Label(tr("Play", "播放"), systemImage: "play.fill")
                        .padding(.horizontal, 16).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColors.magenta)
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .onTapGesture { selectedAlbum = album }
    }

    // MARK: - 横向滚动区

    private func horizontalSection(title: String, albums: [Album]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(BrandColors.textPrimary)
                .padding(.horizontal, 24)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(albums, id: \.id) { album in
                        VStack(alignment: .leading, spacing: 6) {
                            let art = album.artworkHash.flatMap { ArtworkCache.default.path(forHash: $0) }
                                .map { NSImage(byReferencing: $0) }
                            if let img = art {
                                Image(nsImage: img).resizable().scaledToFill()
                                    .frame(width: 140, height: 140)
                                    .clipped().cornerRadius(8)
                            } else {
                                RoundedRectangle(cornerRadius: 8).fill(BrandColors.surface)
                                    .frame(width: 140, height: 140)
                                    .overlay(Image(systemName: "music.note").font(.title))
                            }
                            Text(album.title).font(.caption).lineLimit(1)
                                .foregroundStyle(BrandColors.textPrimary)
                            Text(album.albumArtist).font(.caption2).lineLimit(1)
                                .foregroundStyle(BrandColors.textSecondary)
                        }
                        .frame(width: 140)
                        .onTapGesture { selectedAlbum = album }
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    // MARK: - 全部专辑

    private var allAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("All Albums", "全部专辑"))
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(BrandColors.textPrimary)
                .padding(.horizontal, 24)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 5),
                      spacing: 20) {
                ForEach(albums, id: \.id) { album in
                    AlbumCard(album: album)
                        .onTapGesture { selectedAlbum = album }
                }
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - 辅助

    private func updateGradient() {
        guard let album = heroAlbum,
              let hash = album.artworkHash,
              let path = ArtworkCache.default.path(forHash: hash),
              let img = NSImage(contentsOf: path) else { return }
        let colors = AlbumArtworkExtractor.dominantColors(img, count: 4)
        heroGradient = colors.map { Color(nsColor: $0) } + [BrandColors.background]
    }

    private func playAlbum(_ album: Album) {
        let tracks = library.tracks(in: album)
        let snaps = tracks.map { TrackSnapshot(from: $0) }
        guard let first = snaps.first else { return }
        playback.playTrack(first, context: snaps, from: .album)
    }
}