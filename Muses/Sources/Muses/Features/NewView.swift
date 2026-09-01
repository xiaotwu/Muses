import SwiftUI

/// Apple Music New composition: landscape editorial cards, an adaptive song
/// matrix, and square discovery shelves.
struct NewView: View {
    @Environment(SituationalRecommendationService.self) private var situational
    @Environment(PlaybackService.self) private var playback
    @Environment(LibraryService.self) private var library
    @Environment(FocusService.self) private var focus
    @Environment(YouTubeAccountService.self) private var youTubeAccount
    @Environment(YouTubeSearchService.self) private var youTubeSearch

    @State private var sections: [SituationalSection] = []
    @State private var newTracks: [TrackSnapshot] = []
    @State private var personalSections: [HomeSection] = []
    @State private var recommendationsLoading = true
    @State private var recommendationTask: Task<Void, Never>?
    @State private var personalTask: Task<Void, Never>?

    private var featuredTracks: [TrackSnapshot] {
        Array(newTracks.prefix(3))
    }

    private var bestNewTracks: [TrackSnapshot] {
        let remainder = Array(newTracks.dropFirst(featuredTracks.count).prefix(12))
        return remainder.isEmpty ? Array(newTracks.prefix(12)) : remainder
    }

    private var featuredPersonalCards: [YouTubeDiscoveryCard] {
        personalSections
            .flatMap(\.items)
            .compactMap { item in
                if case .youTube(let card) = item { return card }
                return nil
            }
            .prefix(3)
            .map { $0 }
    }

    private var hasContent: Bool {
        !newTracks.isEmpty || !personalSections.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppleMusicSpacing.section) {
                Text(tr("New", "新发现"))
                    .font(.system(size: AppleMusicTokens.pageTitleSize, weight: .heavy))
                    .foregroundStyle(BrandColors.textPrimary)
                    .padding(.horizontal, AppleMusicTokens.contentPaddingX)

                if focus.isActive {
                    focusState
                } else if recommendationsLoading && !hasContent {
                    loadingState
                } else if hasContent {
                    editorialSection

                    if !bestNewTracks.isEmpty {
                        bestNewSongs
                    }

                    ForEach(personalSections) { section in
                        personalShelf(section)
                    }

                    ForEach(Array(sections.dropFirst())) { section in
                        trackShelf(section)
                    }
                } else {
                    emptyState
                }
            }
            .padding(.top, AppleMusicSpacing.browseTitleTop)
            .padding(.bottom, AppleMusicTokens.scrollBottomInset)
        }
        .background(BrowseBackground())
        .onAppear {
            loadRecommendations()
            loadPersonalDiscovery()
        }
        .onDisappear {
            recommendationTask?.cancel()
            recommendationTask = nil
            personalTask?.cancel()
            personalTask = nil
        }
        .onChange(of: library.likedRevision) { _, _ in loadRecommendations() }
        .onChange(of: library.metadataRevision) { _, _ in loadRecommendations() }
        .onChange(of: library.playRevision) { _, _ in loadRecommendations() }
        .onChange(of: youTubeAccount.isConnected) { _, _ in loadPersonalDiscovery() }
    }

    @ViewBuilder
    private var editorialSection: some View {
        if !featuredTracks.isEmpty || !featuredPersonalCards.isEmpty {
            VStack(alignment: .leading, spacing: 13) {
                SectionHeader(
                    title: tr("Featured", "精选"),
                    subtitle: tr("New music selected for you", "为你挑选的新音乐")
                )
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(featuredTracks) { snapshot in
                            EditorialCard(
                                eyebrow: tr("Featured Song", "精选歌曲"),
                                title: snapshot.title,
                                subtitle: snapshot.artist,
                                artwork: ArtworkSource.resolve(for: snapshot),
                                onOpen: { play(snapshot, context: newTracks) },
                                onPlay: { play(snapshot, context: newTracks) }
                            )
                            .trackContextMenu(snapshot: snapshot, onPlay: {
                                play(snapshot, context: newTracks)
                            })
                        }
                        if featuredTracks.isEmpty {
                            ForEach(featuredPersonalCards) { card in
                                EditorialCard(
                                    eyebrow: "YouTube Music",
                                    title: card.title,
                                    subtitle: card.uploader ?? "YouTube Music",
                                    artwork: ArtworkSource.resolve(
                                        remoteURL: card.thumbnailURL,
                                        youTubeId: card.id),
                                    onOpen: { Task { await play(card) } },
                                    onPlay: { Task { await play(card) } }
                                )
                                .youTubeEntryContextMenu(card: card) {
                                    Task { await play(card) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, AppleMusicTokens.contentPaddingX)
                }
            }
        }
    }

    private var bestNewSongs: some View {
        VStack(alignment: .leading, spacing: 13) {
            SectionHeader(
                title: tr("Best New Songs", "最佳新歌"),
                subtitle: tr("Play in this order", "按此顺序播放")
            )
            LazyVGrid(
                columns: [GridItem(
                    .adaptive(
                        minimum: NewPagePolicy.compactSongColumnMinimum,
                        maximum: 430
                    ),
                    spacing: 18,
                    alignment: .top
                )],
                alignment: .leading,
                spacing: 0
            ) {
                ForEach(bestNewTracks) { snapshot in
                    CompactDiscoveryTrackRow(snapshot: snapshot) {
                        play(snapshot, context: bestNewTracks)
                    }
                    .trackContextMenu(snapshot: snapshot, onPlay: {
                        play(snapshot, context: bestNewTracks)
                    })
                }
            }
            .padding(.horizontal, AppleMusicTokens.contentPaddingX)
        }
    }

    private func trackShelf(_ section: SituationalSection) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            SectionHeader(title: section.title, subtitle: section.subtitle)
            ResponsiveCarousel(cardSize: MusicObjectMetrics.albumRail, spacing: 18) {
                ForEach(section.items.filter { !$0.youTubeId.isEmpty }) { snapshot in
                    AlbumObjectView(
                        title: snapshot.title,
                        subtitle: snapshot.artist,
                        artwork: ArtworkSource.resolve(for: snapshot),
                        size: MusicObjectMetrics.albumRail,
                        role: .play,
                        nowPlayingID: snapshot.id,
                        showsHoverPlay: true,
                        onSelect: {},
                        onPlay: { play(snapshot, context: section.items) }
                    )
                    .trackContextMenu(snapshot: snapshot, onPlay: {
                        play(snapshot, context: section.items)
                    })
                }
            }
        }
    }

    @ViewBuilder
    private func personalShelf(_ section: HomeSection) -> some View {
        let cards = section.items.compactMap { item -> YouTubeDiscoveryCard? in
            if case .youTube(let card) = item { return card }
            return nil
        }
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 13) {
                SectionHeader(title: section.title, subtitle: section.subtitle)
                ResponsiveCarousel(cardSize: MusicObjectMetrics.albumRail, spacing: 18) {
                    ForEach(cards) { card in
                        AlbumObjectView(
                            title: card.title,
                            subtitle: card.uploader ?? "YouTube Music",
                            artwork: ArtworkSource.resolve(
                                remoteURL: card.thumbnailURL,
                                youTubeId: card.id),
                            size: MusicObjectMetrics.albumRail,
                            role: .play,
                            showsHoverPlay: true,
                            onSelect: {},
                            onPlay: { Task { await play(card, siblings: cards) } }
                        )
                        .youTubeEntryContextMenu(card: card) {
                            Task { await play(card, siblings: cards) }
                        }
                    }
                }
            }
        }
    }

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 13) {
                SectionHeader(title: tr("Featured", "精选"))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) {
                        ForEach(0..<2, id: \.self) { _ in
                            SkeletonBlock(
                                width: AppleMusicTokens.editorialWidth,
                                height: AppleMusicTokens.editorialHeight
                            )
                        }
                    }
                    .padding(.horizontal, AppleMusicTokens.contentPaddingX)
                }
            }
            VStack(alignment: .leading, spacing: 13) {
                SectionHeader(title: tr("Best New Songs", "最佳新歌"))
                LazyVGrid(
                    columns: [GridItem(.adaptive(
                        minimum: NewPagePolicy.compactSongColumnMinimum,
                        maximum: 430
                    ), spacing: 18)],
                    spacing: 10
                ) {
                    ForEach(0..<8, id: \.self) { _ in
                        SkeletonBlock(width: 300, height: 56)
                    }
                }
                .padding(.horizontal, AppleMusicTokens.contentPaddingX)
            }
        }
    }

    private var focusState: some View {
        EmptyStateView(
            icon: "brain.head.profile",
            title: tr("Focusing", "专注中"),
            subtitle: tr(
                "New recommendations are hidden while Focus Mode is active.",
                "专注模式开启时会隐藏新推荐。"
            )
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(BrandColors.textSecondary)
            Text(tr("Play more to shape New", "播放更多内容来塑造“新发现”"))
                .font(.headline)
                .foregroundStyle(BrandColors.textPrimary)
            Text(tr(
                "Recommendations use your YouTube library, likes, and listening history.",
                "推荐内容基于你的 YouTube 资料库、喜欢和收听历史。"
            ))
            .font(.subheadline)
            .foregroundStyle(BrandColors.textSecondary)
            Button(tr("Open Search", "打开搜索")) {
                NotificationCenter.default.post(name: .musesFocusSearch, object: nil)
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandColors.magenta)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    private func loadRecommendations() {
        recommendationTask?.cancel()
        recommendationsLoading = true
        recommendationTask = Task {
            let result = await situational.compute()
            guard !Task.isCancelled else { return }
            sections = result
            newTracks = deduplicatedYouTubeTracks(result.flatMap(\.items))
            recommendationsLoading = false
        }
    }

    private func loadPersonalDiscovery() {
        personalTask?.cancel()
        let liked = youTubeAccount.account?.likedVideos ?? []
        let subscriptions = youTubeAccount.account?.subscriptions.map(\.title) ?? []
        guard youTubeAccount.isConnected, (!liked.isEmpty || !subscriptions.isEmpty) else {
            personalSections = []
            return
        }
        personalTask = Task {
            let result = await YouTubePersonalDiscovery.sections(
                liked: liked,
                subscriptionTitles: subscriptions,
                fetchMix: { url in try await youTubeSearch.fetchPlaylist(url: url) },
                search: { query in try await youTubeSearch.search(query: query, limit: 12) }
            )
            guard !Task.isCancelled else { return }
            personalSections = result
        }
    }

    private func deduplicatedYouTubeTracks(_ tracks: [TrackSnapshot]) -> [TrackSnapshot] {
        var seen = Set<String>()
        return tracks.filter { snapshot in
            guard !snapshot.youTubeId.isEmpty else { return false }
            return seen.insert(snapshot.youTubeId).inserted
        }
    }

    private func play(_ snapshot: TrackSnapshot, context: [TrackSnapshot]) {
        let playable = deduplicatedYouTubeTracks(context)
        playback.playTrack(
            snapshot,
            context: playable.isEmpty ? [snapshot] : playable,
            from: .songs
        )
    }

    private func play(_ card: YouTubeDiscoveryCard,
                      siblings: [YouTubeDiscoveryCard]? = nil) async {
        let entry = YTDlpBridge.YTDlpPlaylistEntry(
            id: card.id,
            title: card.title,
            uploader: card.uploader,
            duration: card.duration
        )
        do {
            let snapshot = try await youTubeSearch.importAsTrack(entry: entry)
            let entries = (siblings ?? featuredPersonalCards).map {
                YTDlpBridge.YTDlpPlaylistEntry(
                    id: $0.id,
                    title: $0.title,
                    uploader: $0.uploader,
                    duration: $0.duration
                )
            }
            let context = TrackSnapshot.playbackContext(
                playing: snapshot,
                youTubeEntries: entries
            )
            playback.playTrack(snapshot, context: context, from: .search)
        } catch {
            // Keep the discovery surface stable so the user can retry.
        }
    }
}

private struct CompactDiscoveryTrackRow: View {
    let snapshot: TrackSnapshot
    let onPlay: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 11) {
                ArtworkView(
                    source: ArtworkSource.resolve(for: snapshot),
                    cornerRadius: 5,
                    glyphSize: 16,
                    targetSize: 42
                )
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(BrandColors.textPrimary)
                        .lineLimit(1)
                    Text(snapshot.artist)
                        .font(.caption)
                        .foregroundStyle(BrandColors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                NowPlayingMark(itemID: snapshot.id)
                    .font(.caption)
                YouTubeMark(size: 13)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(height: 58)
            .background(hovering ? BrandColors.surface.opacity(0.7) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(MusesMotion.hoverAnimation(reduceMotion: reduceMotion), value: hovering)
        .overlay(alignment: .bottom) {
            Rectangle().fill(BrandColors.hairline).frame(height: 1)
        }
        .accessibilityLabel("\(snapshot.title), \(snapshot.artist)")
        .accessibilityHint(tr("Play", "播放"))
    }
}
