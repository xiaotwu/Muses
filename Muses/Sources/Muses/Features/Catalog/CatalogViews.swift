import SwiftData
import SwiftUI

struct CatalogReleasesView: View {
    @Binding var selection: CatalogReleaseProjection?
    @Environment(YouTubeCatalogService.self) private var catalog
    @Environment(PlaybackService.self) private var playback
    @State private var releases: [CatalogReleaseProjection] = []
    @State private var loading = true

    private let columns = [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: 20)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader
                if loading {
                    CatalogLoadingGrid()
                } else if releases.isEmpty {
                    CatalogEmptyState(
                        icon: "square.stack",
                        title: tr("No YouTube Music releases yet", "还没有 YouTube Music 发行"),
                        subtitle: tr(
                            "Import or Pull a YouTube Music album (OLAK5uy…) to build this stable-ID catalog.",
                            "导入或拉取 YouTube Music 专辑（OLAK5uy…）后即可建立稳定 ID 目录。"
                        ),
                        onRefresh: refresh
                    )
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(releases) { release in
                            AlbumObjectView(
                                title: release.title,
                                subtitle: releaseSubtitle(release),
                                artwork: releaseArtwork(release),
                                size: 184,
                                showsHoverPlay: !release.tracks.isEmpty,
                                onSelect: { selection = release },
                                onPlay: { play(release.tracks, from: .album) }
                            )
                            .overlay(alignment: .topTrailing) {
                                CatalogStateBadge(state: release.cacheState)
                                    .padding(7)
                            }
                            .catalogReleaseContextMenu(
                                release: release,
                                onOpen: { selection = release },
                                onPlay: { play(release.tracks, from: .album) },
                                onShuffle: { play(release.tracks.shuffled(), from: .album) }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, AppleMusicTokens.contentPaddingX)
            .padding(.top, AppleMusicSpacing.browseTitleTop)
            .padding(.bottom, AppleMusicTokens.scrollBottomInset)
        }
        .background(BrowseBackground())
        .task(id: catalog.revision) { load() }
    }

    private var pageHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(tr("Albums", "专辑"))
                .font(.system(size: AppleMusicTokens.pageTitleSize, weight: .heavy))
                .foregroundStyle(BrandColors.textPrimary)
            Spacer()
            ChromeIconButton(systemName: "arrow.clockwise",
                             help: tr("Refresh Catalog", "刷新目录"),
                             accessibility: tr("Refresh Catalog", "刷新目录"),
                             action: refresh)
        }
    }

    private func load() {
        releases = catalog.releases()
        loading = false
    }

    private func refresh() {
        loading = true
        catalog.rebuildFromTrackMetadata()
        load()
    }

    private func releaseSubtitle(_ release: CatalogReleaseProjection) -> String {
        let year = release.year.map(String.init) ?? ""
        return [release.artistName, year].filter { !$0.isEmpty }.joined(separator: " • ")
    }

    private func releaseArtwork(_ release: CatalogReleaseProjection) -> ArtworkSource {
        ArtworkSource.resolve(remoteURL: release.artworkURL,
                              youTubeId: release.tracks.first?.youTubeId)
    }

    private func play(_ tracks: [TrackSnapshot], from source: QueueSource) {
        guard let first = tracks.first else { return }
        playback.playTrack(first, context: tracks, from: source)
    }
}

struct CatalogArtistsView: View {
    @Binding var selection: CatalogArtistProjection?
    @Environment(YouTubeCatalogService.self) private var catalog
    @Environment(PlaybackService.self) private var playback
    @State private var artists: [CatalogArtistProjection] = []
    @State private var loading = true

    private let columns = [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: 20)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    Text(tr("Artists", "艺术家"))
                        .font(.system(size: AppleMusicTokens.pageTitleSize, weight: .heavy))
                        .foregroundStyle(BrandColors.textPrimary)
                    Spacer()
                    ChromeIconButton(systemName: "arrow.clockwise",
                                     help: tr("Refresh Catalog", "刷新目录"),
                                     accessibility: tr("Refresh Catalog", "刷新目录"),
                                     action: refresh)
                }

                if loading {
                    CatalogLoadingGrid()
                } else if artists.isEmpty {
                    CatalogEmptyState(
                        icon: "person.2",
                        title: tr("No identified artists yet", "还没有已识别的艺术家"),
                        subtitle: tr(
                            "Pull music with channel metadata. Artists are never merged by name alone.",
                            "请拉取带频道元数据的音乐。艺术家绝不会仅按名称合并。"
                        ),
                        onRefresh: refresh
                    )
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(artists) { artist in
                            ArtistObjectView(
                                name: artist.name,
                                detail: tr("\(artist.tracks.count) songs", "\(artist.tracks.count) 首歌曲"),
                                artwork: artistArtwork(artist),
                                size: 184,
                                showsHoverPlay: !artist.tracks.isEmpty,
                                onSelect: { selection = artist },
                                onPlay: { play(artist.tracks) }
                            )
                            .overlay(alignment: .topTrailing) {
                                CatalogStateBadge(state: artist.cacheState)
                                    .padding(7)
                            }
                            .catalogArtistContextMenu(
                                artist: artist,
                                onOpen: { selection = artist },
                                onPlay: { play(artist.tracks) },
                                onShuffle: { play(artist.tracks.shuffled()) }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, AppleMusicTokens.contentPaddingX)
            .padding(.top, AppleMusicSpacing.browseTitleTop)
            .padding(.bottom, AppleMusicTokens.scrollBottomInset)
        }
        .background(BrowseBackground())
        .task(id: catalog.revision) { load() }
    }

    private func load() {
        artists = catalog.artists()
        loading = false
    }

    private func refresh() {
        loading = true
        catalog.rebuildFromTrackMetadata()
        load()
    }

    private func artistArtwork(_ artist: CatalogArtistProjection) -> ArtworkSource {
        ArtworkSource.resolve(remoteURL: artist.artworkURL,
                              youTubeId: artist.tracks.first?.youTubeId)
    }

    private func play(_ tracks: [TrackSnapshot]) {
        guard let first = tracks.first else { return }
        playback.playTrack(first, context: tracks, from: .artist)
    }
}

struct CatalogReleaseDetailView: View {
    let release: CatalogReleaseProjection
    @Binding var selection: CatalogReleaseProjection?
    @Environment(PlaybackService.self) private var playback
    @Query(sort: \Playlist.name) private var playlists: [Playlist]

    var body: some View {
        let rows = release.tracks.enumerated().map {
            CollectionTrackRow(snapshot: $0.element, canonicalIndex: $0.offset,
                               year: release.year)
        }
        CollectionPage(
            title: release.title,
            subtitle: releaseDetailSubtitle,
            rows: rows,
            defaultSort: .playlistOrder,
            currentTrack: playback.state.track,
            playlists: playlists,
            emptyIcon: "square.stack",
            emptyTitle: tr("No available tracks", "没有可播放曲目"),
            emptySubtitle: tr("Refresh this release to rebuild its membership.",
                              "刷新此发行以重建曲目成员关系。"),
            onPlay: { play($0.snapshot) }
        ) {
            HStack(spacing: 8) {
                ChromeIconButton(systemName: "chevron.backward",
                                 help: tr("Back", "返回"),
                                 accessibility: tr("Back", "返回")) { selection = nil }
                ChromeIconButton(systemName: "play.fill",
                                 help: tr("Play All", "播放全部"),
                                 accessibility: tr("Play All", "播放全部")) { playAll() }
                ChromeIconButton(systemName: "shuffle",
                                 help: tr("Shuffle", "随机播放"),
                                 accessibility: tr("Shuffle", "随机播放")) { shuffle() }
            }
        }
    }

    private var releaseDetailSubtitle: String {
        let state: String
        switch release.cacheState {
        case .fresh: state = tr("Up to date", "已是最新")
        case .stale: state = tr("Cached • Refresh recommended", "缓存内容 • 建议刷新")
        case .unavailable: state = tr("Currently unavailable", "当前不可用")
        }
        return "\(release.artistName) • \(release.tracks.count) • \(state)"
    }

    private func play(_ snapshot: TrackSnapshot) {
        playback.playTrack(snapshot, context: release.tracks, from: .album)
    }

    private func playAll() {
        guard let first = release.tracks.first else { return }
        playback.playTrack(first, context: release.tracks, from: .album)
    }

    private func shuffle() {
        let tracks = release.tracks.shuffled()
        guard let first = tracks.first else { return }
        playback.playTrack(first, context: tracks, from: .album)
    }
}

struct CatalogArtistDetailView: View {
    let artist: CatalogArtistProjection
    @Binding var selection: CatalogArtistProjection?
    @Environment(PlaybackService.self) private var playback
    @Query(sort: \Playlist.name) private var playlists: [Playlist]

    var body: some View {
        let ordered = artist.tracks.sorted {
            let result = $0.title.localizedStandardCompare($1.title)
            if result != .orderedSame { return result == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
        let rows = ordered.enumerated().map {
            CollectionTrackRow(snapshot: $0.element, canonicalIndex: $0.offset)
        }
        CollectionPage(
            title: artist.name,
            subtitle: tr("\(rows.count) songs • Title A–Z • stable artist identity",
                         "\(rows.count) 首歌曲 • 标题 A–Z • 稳定艺术家身份"),
            rows: rows,
            defaultSort: .titleAZ,
            currentTrack: playback.state.track,
            playlists: playlists,
            emptyIcon: "person.crop.circle",
            emptyTitle: tr("No available songs", "没有可播放歌曲"),
            emptySubtitle: tr("Refresh the artist catalog to rebuild membership.",
                              "刷新艺术家目录以重建成员关系。"),
            onPlay: { row in
                playback.playTrack(row.snapshot, context: ordered, from: .artist)
            }
        ) {
            HStack(spacing: 8) {
                ChromeIconButton(systemName: "chevron.backward",
                                 help: tr("Back", "返回"),
                                 accessibility: tr("Back", "返回")) { selection = nil }
                ChromeIconButton(systemName: "play.fill",
                                 help: tr("Play All", "播放全部"),
                                 accessibility: tr("Play All", "播放全部")) {
                    guard let first = ordered.first else { return }
                    playback.playTrack(first, context: ordered, from: .artist)
                }
                ChromeIconButton(systemName: "shuffle",
                                 help: tr("Shuffle", "随机播放"),
                                 accessibility: tr("Shuffle", "随机播放")) {
                    let shuffled = ordered.shuffled()
                    guard let first = shuffled.first else { return }
                    playback.playTrack(first, context: shuffled, from: .artist)
                }
            }
        }
    }
}

private struct CatalogLoadingGrid: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: 20)],
                  spacing: 24) {
            ForEach(0..<8, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(BrandColors.surface)
                        .aspectRatio(1, contentMode: .fit)
                    RoundedRectangle(cornerRadius: 4).fill(BrandColors.surface)
                        .frame(height: 12)
                    RoundedRectangle(cornerRadius: 4).fill(BrandColors.surface.opacity(0.7))
                        .frame(width: 110, height: 10)
                }
                .redacted(reason: .placeholder)
            }
        }
        .accessibilityLabel(tr("Loading catalog", "正在载入目录"))
    }
}

private struct CatalogEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(BrandColors.textSecondary)
            Text(title).font(.headline).foregroundStyle(BrandColors.textPrimary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(BrandColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button(action: onRefresh) {
                Label(tr("Refresh", "刷新"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandColors.magenta)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

private struct CatalogStateBadge: View {
    let state: CatalogCacheState

    var body: some View {
        switch state {
        case .fresh:
            EmptyView()
        case .stale:
            Image(systemName: "clock.badge.exclamationmark")
                .font(.caption.weight(.semibold))
                .padding(6)
                .background(.ultraThinMaterial, in: Circle())
                .help(tr("Cached metadata is stale", "缓存元数据已过期"))
        case .unavailable:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(BrandColors.magenta)
                .padding(6)
                .background(.ultraThinMaterial, in: Circle())
                .help(tr("Currently unavailable", "当前不可用"))
        }
    }
}
