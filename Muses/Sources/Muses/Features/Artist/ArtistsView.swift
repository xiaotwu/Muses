import SwiftUI

struct ArtistsView: View {
    @Binding var selectedArtist: Artist?
    @Binding var selectedBrowsableArtist: BrowsableArtist?
    @Environment(LibraryService.self) private var library
    @Environment(PlaybackService.self) private var playback
    @Environment(MetadataEnrichmentService.self) private var enrichment
    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var projection = BrowseProjection.empty

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: 5)
    }

    var body: some View {
        let artists = filteredArtists()
        let derivedArtists = projection.artists.filter { !$0.isLocal }
            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
        ScrollView {
            if artists.isEmpty && derivedArtists.isEmpty {
                EmptyStateView(
                    icon: "person.2",
                    title: searchText.isEmpty ? tr("No artists in library", "资料库中没有艺术家") : tr("No results", "无搜索结果"))
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(artists, id: \.id) { artist in
                        ArtistObjectView(
                            name: artist.name,
                            detail: "\(artist.albums.count) \(tr("albums", "张专辑"))",
                            artwork: ArtworkSource.localHash(artist.artworkHash),
                            size: MusicObjectMetrics.artistGrid,
                            onSelect: { selectedArtist = artist },
                            onPlay: { playArtist(artist, shuffle: false) }
                        )
                        .contextMenu {
                            Button(tr("Play", "播放")) { playArtist(artist, shuffle: false) }
                            Button(tr("Shuffle", "随机播放")) { playArtist(artist, shuffle: true) }
                        }
                    }
                }
                .padding(20)

                // P3 — YouTube-derived 艺术家(MusicBrainz 确认 ≥0.70 后 surfaced)。
                if !derivedArtists.isEmpty {
                    HStack {
                        Text(tr("YouTube", "YouTube")).font(.headline)
                            .foregroundStyle(BrandColors.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(derivedArtists) { browsable in
                            BrowsableArtistCard(
                                browsable: browsable,
                                onSelect: { selectedBrowsableArtist = browsable },
                                onPlay: { playBrowsable(browsable) }
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle(tr("Artists", "艺术家"))
        .searchable(text: $searchText, prompt: tr("Search artists", "搜索艺术家"))
        .onChange(of: searchText) { _, newValue in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                debouncedSearch = newValue
            }
        }
        .background(BrandColors.background)
        .task { await loadProjection() }
        .onChange(of: enrichment.enrichmentRevision) { _, _ in
            Task { await loadProjection() }
        }
    }

    private var q: String { debouncedSearch.trimmingCharacters(in: .whitespaces) }

    private func filteredArtists() -> [Artist] {
        let all = library.allArtists()
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    /// 艺术家卡片右键:播放该艺术家全部曲目(可选随机)。
    private func playArtist(_ artist: Artist, shuffle: Bool) {
        var snaps = library.tracks(byArtist: artist).map { TrackSnapshot(from: $0) }
        guard !snaps.isEmpty else { return }
        if shuffle { snaps.shuffle() }
        playback.playTrack(snaps[0], context: snaps, from: .artist)
    }

    private func playBrowsable(_ browsable: BrowsableArtist) {
        guard let first = browsable.trackSnapshots.first else { return }
        playback.playTrack(first, context: browsable.trackSnapshots, from: .artist)
    }

    private func loadProjection() async {
        await enrichment.refreshCandidates()
        projection = await enrichment.projection()
        await enrichment.enrichDerived()
        projection = await enrichment.projection()
    }
}