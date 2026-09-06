import SwiftData
import SwiftUI

/// Shared Songs/playlist composition: a centered all-track card deck and a
/// complete native table that remain mounted across presentation changes.
struct CollectionPage<Controls: View>: View {
    let title: String
    let subtitle: String
    let youTubeURL: URL?
    let rows: [CollectionTrackRow]
    let defaultSort: CollectionTableDefaultSort
    let currentTrack: TrackSnapshot?
    var playlists: [Playlist] = []
    var emptyIcon: String = "music.note.list"
    var emptyTitle: String
    var emptySubtitle: String
    let onPlay: (CollectionTrackRow) -> Void
    var onRemove: ((CollectionTrackRow) -> Void)? = nil
    private let controls: Controls

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mode = CollectionPageMode.stage

    init(
        title: String,
        subtitle: String,
        youTubeURL: URL? = nil,
        rows: [CollectionTrackRow],
        defaultSort: CollectionTableDefaultSort,
        currentTrack: TrackSnapshot?,
        playlists: [Playlist] = [],
        emptyIcon: String = "music.note.list",
        emptyTitle: String,
        emptySubtitle: String,
        onPlay: @escaping (CollectionTrackRow) -> Void,
        onRemove: ((CollectionTrackRow) -> Void)? = nil,
        @ViewBuilder controls: () -> Controls
    ) {
        self.title = title
        self.subtitle = subtitle
        self.youTubeURL = youTubeURL
        self.rows = rows
        self.defaultSort = defaultSort
        self.currentTrack = currentTrack
        self.playlists = playlists
        self.emptyIcon = emptyIcon
        self.emptyTitle = emptyTitle
        self.emptySubtitle = emptySubtitle
        self.onPlay = onPlay
        self.onRemove = onRemove
        self.controls = controls()
    }

    @ViewBuilder
    var body: some View {
        if rows.isEmpty {
            CollectionEmptyPanel(
                title: title,
                subtitle: subtitle,
                youTubeURL: youTubeURL,
                icon: emptyIcon,
                emptyTitle: emptyTitle,
                emptySubtitle: emptySubtitle,
                controls: controls
            )
            .background(BrandColors.background)
        } else {
            ZStack {
                CollectionDeckStage(
                    title: title,
                    subtitle: subtitle,
                    youTubeURL: youTubeURL,
                    rows: rows,
                    currentTrack: currentTrack,
                    playlists: playlists,
                    isInteractionEnabled: mode == .stage,
                    onPlay: onPlay,
                    onRemove: onRemove,
                    onExpand: { transition(to: .list) },
                    controls: controls
                )
                .opacity(mode == .stage ? 1 : 0)
                .offset(y: mode == .stage ? 0 : -22)
                .allowsHitTesting(mode == .stage)
                .disabled(mode != .stage)
                .accessibilityHidden(mode != .stage)

                CollectionListPanel(
                    title: title,
                    subtitle: subtitle,
                    youTubeURL: youTubeURL,
                    rows: rows,
                    defaultSort: defaultSort,
                    currentTrack: currentTrack,
                    playlists: playlists,
                    onPlay: onPlay,
                    onRemove: onRemove,
                    onCollapse: { transition(to: .stage) },
                    controls: controls
                )
                .opacity(mode == .list ? 1 : 0)
                .offset(y: mode == .list ? 0 : 26)
                .allowsHitTesting(mode == .list)
                .disabled(mode != .list)
                .accessibilityHidden(mode != .list)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .background(BrandColors.background)
            .onExitCommand {
                if mode == .list {
                    transition(to: .stage)
                }
            }
            .onChange(of: title) { _, _ in
                mode = .stage
            }
        }
    }

    private func transition(to newMode: CollectionPageMode) {
        guard mode != newMode else { return }
        if let animation = MusesMotion.collectionListAnimation(reduceMotion: reduceMotion) {
            withAnimation(animation) {
                mode = newMode
            }
        } else {
            mode = newMode
        }
    }
}

private struct CollectionEmptyPanel<Controls: View>: View {
    let title: String
    let subtitle: String
    let youTubeURL: URL?
    let icon: String
    let emptyTitle: String
    let emptySubtitle: String
    let controls: Controls

    var body: some View {
        VStack(spacing: 0) {
            CollectionPageHeader(title: title, youTubeURL: youTubeURL) {
                controls
            }
            .padding(.horizontal, AppleMusicTokens.contentPaddingX)
            .padding(.top, AppleMusicSpacing.browseTitleTop)

            EmptyStateView(icon: icon, title: emptyTitle, subtitle: emptySubtitle)
                .padding(.top, AppleMusicSpacing.headerToPrimary)
        }
    }
}

/// One page-level title/action row shared by every collection presentation.
/// Controls stay on the same visual line as the title while the row reserves a
/// full native interaction height for pointer, keyboard, and accessibility use.
struct CollectionPageHeader<Controls: View>: View {
    let title: String
    let youTubeURL: URL?
    private let controls: Controls

    init(
        title: String,
        youTubeURL: URL? = nil,
        @ViewBuilder controls: () -> Controls
    ) {
        self.title = title
        self.youTubeURL = youTubeURL
        self.controls = controls()
    }

    var body: some View {
        HStack(alignment: .center, spacing: AppleMusicSpacing.related) {
            HStack(alignment: .center, spacing: 10) {
                Text(title)
                    .font(.system(size: AppleMusicTokens.pageTitleSize, weight: .heavy))
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let youTubeURL {
                    Link(destination: youTubeURL) {
                        YouTubeMark(size: 16)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help(tr("Open on YouTube", "在 YouTube 打开"))
                    .accessibilityLabel(tr(
                        "Open playlist on YouTube",
                        "在 YouTube 打开此歌单"
                    ))
                    .fixedSize()
                }
            }
                .layoutPriority(1)

            Spacer(minLength: AppleMusicSpacing.related)

            controls
                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

private struct CollectionListPanel<Controls: View>: View {
    let title: String
    let subtitle: String
    let youTubeURL: URL?
    let rows: [CollectionTrackRow]
    let defaultSort: CollectionTableDefaultSort
    let currentTrack: TrackSnapshot?
    let playlists: [Playlist]
    let onPlay: (CollectionTrackRow) -> Void
    let onRemove: ((CollectionTrackRow) -> Void)?
    let onCollapse: () -> Void
    let controls: Controls

    var body: some View {
        VStack(spacing: 0) {
            CollectionPageHeader(title: title, youTubeURL: youTubeURL) {
                controls
            }
            .padding(.horizontal, AppleMusicTokens.contentPaddingX)
            .padding(.top, AppleMusicSpacing.browseTitleTop)

            CollectionExpansionHandle(
                direction: .down,
                accessibilityLabel: tr("Return to song card deck", "返回歌曲卡片牌组"),
                help: tr("Return to song card deck", "返回歌曲卡片牌组"),
                action: onCollapse
            )
            .padding(.top, AppleMusicSpacing.headerToPrimary)
            .padding(.bottom, AppleMusicSpacing.related)

            Rectangle()
                .fill(BrandColors.hairline)
                .frame(height: 1)
                .padding(.horizontal, AppleMusicTokens.contentPaddingX)

            CollectionTrackTable(
                rows: rows,
                defaultSort: defaultSort,
                currentTrack: currentTrack,
                playlists: playlists,
                onPlay: onPlay,
                onRemove: onRemove
            )
        }
        .background(BrandColors.background)
    }
}

private struct CollectionTrackTable: View {
    let rows: [CollectionTrackRow]
    let defaultSort: CollectionTableDefaultSort
    let currentTrack: TrackSnapshot?
    let playlists: [Playlist]
    let onPlay: (CollectionTrackRow) -> Void
    let onRemove: ((CollectionTrackRow) -> Void)?

    @Environment(LibraryService.self) private var library
    @Environment(PlaylistService.self) private var playlistService
    @Environment(PlaybackService.self) private var playback
    @Environment(InboxService.self) private var inbox
    @State private var selection = Set<UUID>()
    @State private var sortOrder: [KeyPathComparator<CollectionTrackRow>]
    @State private var columnCustomization = TableColumnCustomization<CollectionTrackRow>()
    @State private var likedIDs = Set<UUID>()
    @State private var editingTrack: Track?
    @State private var notesTrack: Track?
    @State private var pendingNewPlaylistTrackID: UUID?
    @State private var showCreatePlaylist = false

    init(
        rows: [CollectionTrackRow],
        defaultSort: CollectionTableDefaultSort,
        currentTrack: TrackSnapshot?,
        playlists: [Playlist],
        onPlay: @escaping (CollectionTrackRow) -> Void,
        onRemove: ((CollectionTrackRow) -> Void)?
    ) {
        self.rows = rows
        self.defaultSort = defaultSort
        self.currentTrack = currentTrack
        self.playlists = playlists
        self.onPlay = onPlay
        self.onRemove = onRemove
        _sortOrder = State(initialValue: defaultSort.comparators)
    }

    private var displayedRows: [CollectionTrackRow] {
        CollectionTrackSort.rows(rows, using: sortOrder)
    }

    var body: some View {
        Table(
            displayedRows,
            selection: $selection,
            sortOrder: $sortOrder,
            columnCustomization: $columnCustomization
        ) {
            TableColumn(tr("Order", "顺序"), value: \.canonicalIndex) { row in
                Text("\(row.canonicalIndex + 1)")
                    .foregroundStyle(BrandColors.textSecondary)
                    .monospacedDigit()
            }
            .width(min: 44, ideal: 52, max: 72)
            .customizationID("collection-order")

            TableColumn(
                tr("Title", "标题"),
                value: \.title,
                comparator: .localizedStandard
            ) { row in
                CollectionTrackTitleCell(
                    row: row,
                    liked: likedIDs.contains(row.id),
                    isPlaying: matchesCurrent(row),
                    onPlay: { onPlay(row) },
                    onToggleLike: { library.toggleLike(id: row.id) }
                )
            }
            .width(min: 220, ideal: 300)
            .customizationID("collection-title")
            .disabledCustomizationBehavior(.visibility)

            TableColumn(
                tr("Artist", "艺术家"),
                value: \.artist,
                comparator: .localizedStandard
            ) { row in
                secondaryText(row.artist)
            }
            .width(min: 120, ideal: 170)
            .customizationID("collection-artist")

            TableColumn(
                tr("Album", "专辑"),
                value: \.album,
                comparator: .localizedStandard
            ) { row in
                secondaryText(row.album)
            }
            .width(min: 130, ideal: 190)
            .customizationID("collection-album")

            TableColumn(tr("Year", "年份"), value: \.yearSortValue) { row in
                secondaryText(row.year.map(String.init) ?? "—")
                    .monospacedDigit()
            }
            .width(min: 58, ideal: 66, max: 82)
            .customizationID("collection-year")

            TableColumn(
                tr("Genre", "类型"),
                value: \.genreSortValue,
                comparator: .localizedStandard
            ) { row in
                secondaryText(row.genre ?? "—")
            }
            .width(min: 90, ideal: 120)
            .customizationID("collection-genre")

            TableColumn(tr("Time", "时长"), value: \.duration) { row in
                secondaryText(formatDuration(row.duration))
                    .monospacedDigit()
            }
            .width(min: 64, ideal: 72, max: 86)
            .customizationID("collection-duration")

            TableColumn(tr("Date Added", "添加日期"), value: \.addedAtSortValue) { row in
                secondaryText(formatDate(row.addedAt))
            }
            .width(min: 100, ideal: 124)
            .customizationID("collection-date-added")

            TableColumn(tr("Plays", "播放次数"), value: \.playCount) { row in
                secondaryText("\(row.playCount)")
                    .monospacedDigit()
            }
            .width(min: 62, ideal: 72, max: 92)
            .customizationID("collection-plays")

        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .background(BrandColors.background)
        .contextMenu(forSelectionType: UUID.self) { selectedIDs in
            contextMenu(for: selectedIDs)
        } primaryAction: { selectedIDs in
            guard let row = firstRow(in: selectedIDs) else { return }
            onPlay(row)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: OverlayChromeMetrics.scrollBottomInset)
        }
        .task(id: rows.map(\.id)) { refreshLikedIDs() }
        .onChange(of: library.likedRevision) { _, _ in refreshLikedIDs() }
        .onChange(of: defaultSort) { _, newValue in
            sortOrder = newValue.comparators
        }
        .sheet(item: $editingTrack) { track in
            EditTrackSheet(track: track)
        }
        .sheet(item: $notesTrack) { track in
            TrackNotesSheet(track: track)
        }
        .sheet(isPresented: $showCreatePlaylist) {
            NewPlaylistSheet(isPresented: $showCreatePlaylist) { name in
                guard let id = pendingNewPlaylistTrackID,
                      let track = library.track(by: id) else { return }
                let playlist = playlistService.create(name: name)
                playlistService.addTrack(playlist, track: track)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for selectedIDs: Set<UUID>) -> some View {
        if let row = firstRow(in: selectedIDs) {
            TrackContextMenuItems(
                snapshot: row.snapshot,
                playlists: playlists,
                onPlay: { onPlay(row) },
                onRemoveFromContainer: onRemove.map { handler in { handler(row) } },
                onEditTrack: { editingTrack = library.track(by: row.id) },
                onTrackNotes: { notesTrack = library.track(by: row.id) },
                onCreatePlaylist: {
                    pendingNewPlaylistTrackID = row.id
                    showCreatePlaylist = true
                }
            )
            .environment(playback)
            .environment(library)
            .environment(inbox)
            .environment(playlistService)
        }
    }

    private func firstRow(in selectedIDs: Set<UUID>) -> CollectionTrackRow? {
        displayedRows.first { selectedIDs.contains($0.id) }
    }

    private func refreshLikedIDs() {
        likedIDs = library.likedIDs(for: rows.map(\.id))
    }

    private func matchesCurrent(_ row: CollectionTrackRow) -> Bool {
        guard let currentTrack else { return false }
        return currentTrack.id == row.id
            || (!currentTrack.youTubeId.isEmpty
                && currentTrack.youTubeId == row.snapshot.youTubeId)
    }

    private func secondaryText(_ value: String) -> some View {
        Text(value.isEmpty ? "—" : value)
            .font(.system(size: 12.5))
            .foregroundStyle(BrandColors.textSecondary)
            .lineLimit(1)
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func formatDate(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .omitted) ?? "—"
    }
}

private struct CollectionTrackTitleCell: View {
    let row: CollectionTrackRow
    let liked: Bool
    let isPlaying: Bool
    let onPlay: () -> Void
    let onToggleLike: () -> Void

    @State private var hoveringArtwork = false

    var body: some View {
        HStack(spacing: AppleMusicSpacing.tableCell) {
            Button(action: onPlay) {
                ArtworkView(
                    source: ArtworkSource.resolve(for: row.snapshot),
                    cornerRadius: 5,
                    glyphSize: 13,
                    targetSize: AppleMusicTokens.trackArtworkSize
                )
                .overlay {
                    if hoveringArtwork || isPlaying {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.black.opacity(0.38))
                        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .onHover { hoveringArtwork = $0 }
            .help(tr("Play \(row.title)", "播放 \(row.title)"))
            .accessibilityLabel(tr("Play \(row.title)", "播放 \(row.title)"))

            Text(row.title)
                .font(.system(size: 13, weight: isPlaying ? .semibold : .regular))
                .foregroundStyle(isPlaying ? BrandColors.magenta : BrandColors.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button(action: onToggleLike) {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(liked ? BrandColors.magenta : BrandColors.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(liked ? tr("Unlike", "取消收藏") : tr("Like", "收藏"))
            .accessibilityLabel(liked ? tr("Unlike \(row.title)", "取消收藏 \(row.title)")
                                      : tr("Like \(row.title)", "收藏 \(row.title)"))
        }
        .frame(minHeight: 42)
    }
}
