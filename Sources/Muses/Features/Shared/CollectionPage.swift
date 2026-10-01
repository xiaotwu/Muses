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
    var emptyActionTitle: String? = nil
    var emptyAction: (() -> Void)? = nil
    let onPlay: (CollectionTrackRow) -> Void
    var onRemove: ((CollectionTrackRow) -> Void)? = nil
    private let controls: Controls

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mode = CollectionPageMode.stage
    @State private var locateRequest = 0
    @State private var pendingRemoval: ActionConfirmation?
    @State private var removalRows: [CollectionTrackRow] = []
    @Environment(PlaybackService.self) private var playback
    @Environment(\.collectionPresentation) private var presentation

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
        emptyActionTitle: String? = nil,
        emptyAction: (() -> Void)? = nil,
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
        self.emptyActionTitle = emptyActionTitle
        self.emptyAction = emptyAction
        self.onPlay = onPlay
        self.onRemove = onRemove
        self.controls = controls()
    }

    var body: some View {
        pageContent.actionConfirmation($pendingRemoval)
            .onChange(of: pendingRemoval == nil) { _, cleared in
                if cleared { removalRows = [] }
            }
    }

    @ViewBuilder
    private var pageContent: some View {
        if rows.isEmpty {
            CollectionEmptyPanel(
                title: title,
                subtitle: subtitle,
                youTubeURL: youTubeURL,
                icon: emptyIcon,
                emptyTitle: emptyTitle,
                emptySubtitle: emptySubtitle,
                emptyActionTitle: emptyActionTitle,
                emptyAction: emptyAction,
                controls: controls
            )
            .background(BrandColors.background)
        } else {
            ZStack {
                RetainedCollectionSurface(isVisible: mode == .stage) {
                    CollectionDeckStage(
                        title: title,
                        subtitle: subtitle,
                        youTubeURL: youTubeURL,
                        rows: rows,
                        currentTrack: currentTrack,
                        playlists: playlists,
                        isInteractionEnabled: mode == .stage,
                        locateRequest: locateRequest,
                        onPlay: onPlay,
                        onRemove: confirmedRemoval,
                        onExpand: { transition(to: .list) },
                        controls: controls
                    )
                    .opacity(mode == .stage ? 1 : 0)
                    .offset(y: mode == .stage ? 0 : -22)
                    .allowsHitTesting(mode == .stage)
                    .disabled(mode != .stage)
                    .accessibilityHidden(mode != .stage)
                }

                RetainedCollectionSurface(isVisible: mode == .list) {
                    CollectionListPanel(
                        title: title,
                        subtitle: subtitle,
                        youTubeURL: youTubeURL,
                        rows: rows,
                        defaultSort: defaultSort,
                        currentTrack: currentTrack,
                        playlists: playlists,
                        onPlay: onPlay,
                        onRemove: confirmedRemoval,
                        onCollapse: { transition(to: .stage) },
                        controls: controls
                    )
                    .opacity(mode == .list ? 1 : 0)
                    .offset(y: mode == .list ? 0 : 26)
                    .allowsHitTesting(mode == .list)
                    .disabled(mode != .list)
                    .accessibilityHidden(mode != .list)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .background(BrandColors.background)
            .onExitCommand {
                if mode == .list, pendingRemoval == nil {
                    transition(to: .stage)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if playback.state.isPlaying, rows.contains(where: { $0.matches(currentTrack) }) {
                    ChromeIconButton(systemName: "scope",
                        help: tr("Show playing song", "定位正在播放的歌曲"),
                        accessibility: tr("Show playing song", "定位正在播放的歌曲")) {
                            transition(to: .stage)
                            locateRequest &+= 1
                        }
                        .padding(.trailing, 24)
                        .padding(.bottom, OverlayChromeMetrics.scrollBottomInset + 16)
                }
            }
            .onAppear { mode = presentation?.mode ?? .stage }
            .onChange(of: mode) { _, value in presentation?.mode = value }
        }
    }

    private var confirmedRemoval: ((CollectionTrackRow) -> Void)? {
        guard let onRemove else { return nil }
        return { row in
            if !removalRows.contains(where: { $0.id == row.id }) { removalRows.append(row) }
            let selected = removalRows
            pendingRemoval = ActionConfirmation(
                title: tr("Remove songs from this playlist?", "从此歌单移除歌曲？"),
                message: tr("\(removalRows.count) songs will be removed from ‘\(title)’ on this Mac. Push is required to update YTM.",
                            "将从本机的“\(title)”移除 \(removalRows.count) 首歌曲。更新 YTM 需要另外推送。"),
                actionTitle: tr("Remove", "移除")) {
                    removalRows = []
                    for item in selected { onRemove(item) }
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
    var emptyActionTitle: String? = nil
    var emptyAction: (() -> Void)? = nil
    let controls: Controls

    var body: some View {
        VStack(spacing: 0) {
            CollectionPageHeader(title: title, youTubeURL: youTubeURL) {
                controls
            }
            .padding(.horizontal, AppleMusicTokens.contentPaddingX)
            .padding(.top, AppleMusicSpacing.browseTitleTop)

            EmptyStateView(
                icon: icon,
                title: emptyTitle,
                subtitle: emptySubtitle,
                actionTitle: emptyActionTitle,
                action: emptyAction
            )
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
                    .font(MusesTypography.heading(title))
                    .foregroundStyle(BrandColors.heading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)


            }
                .layoutPriority(1)

            Spacer(minLength: AppleMusicSpacing.related)

            MusesGlassGroup(spacing: 8) {
            HStack(spacing: 16) {
                controls
                if youTubeURL != nil { Divider().frame(height: 20) }
                if let youTubeURL {
                    if let target = YouTubeShareTarget(url: youTubeURL) {
                        YouTubeShareMenu(target: target, chrome: true)
                    }
                    Link(destination: youTubeURL) {
                        YouTubeMark(size: 14).chromeActionCircle()
                    }
                    .buttonStyle(.fullAreaPlain)
                    .help(tr("Open on YouTube", "在 YouTube 打开"))
                    .accessibilityLabel(tr(
                        "Open playlist on YouTube",
                        "在 YouTube 打开此歌单"
                    ))
                    .fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 44, alignment: .trailing)
            .environment(\.groupedChromeActions, true)
            .musesGlass(in: Capsule(), role: .compactControl)
            }
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
    @Environment(\.collectionPresentation) private var presentation
    @State private var selection = Set<UUID>()
    @State private var sortOrder: [KeyPathComparator<CollectionTrackRow>]
    @State private var columnCustomization = TableColumnCustomization<CollectionTrackRow>()
    @State private var likedIDs = Set<UUID>()
    @State private var editingTrack: Track?
    @State private var notesTrack: Track?
    @State private var pendingNewPlaylistTrackID: UUID?
    @State private var showCreatePlaylist = false
    @State private var accessiblePage = 0
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @AppStorage(PrefKey.accessibleCollectionTables) private var pagedTablesEnabled = false
    private let accessiblePageSize = 25

    private var usesAccessiblePages: Bool { voiceOverEnabled || pagedTablesEnabled }

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

    // Sort only when data or sort criteria change, not once per row menu,
    // playback update, selection change, and accessibility page calculation.
    @State private var displayedRows: [CollectionTrackRow] = []

    private var accessiblePageCount: Int {
        CollectionTablePaging.pageCount(rowCount: rows.count,
                                        pageSize: accessiblePageSize)
    }

    private var tableRows: [CollectionTrackRow] {
        guard usesAccessiblePages, displayedRows.count > accessiblePageSize else { return displayedRows }
        return CollectionTablePaging.rows(displayedRows, page: accessiblePage,
                                          pageSize: accessiblePageSize)
    }

    var body: some View {
        VStack(spacing: 0) {
        if usesAccessiblePages {
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Menu {
                    Button(tr("Collection order", "歌单顺序", zhHant: "歌單順序")) {
                        sortOrder = [KeyPathComparator(\.canonicalIndex)]
                    }
                    Button(tr("Title", "标题", zhHant: "標題")) {
                        sortOrder = [KeyPathComparator(\.title, comparator: .localizedStandard)]
                    }
                    Button(tr("Artist", "艺术家", zhHant: "藝術家")) {
                        sortOrder = [KeyPathComparator(\.artist, comparator: .localizedStandard)]
                    }
                    Button(tr("Album", "专辑", zhHant: "專輯")) {
                        sortOrder = [KeyPathComparator(\.album, comparator: .localizedStandard)]
                    }
                    Button(tr("Time", "时长", zhHant: "時長")) {
                        sortOrder = [KeyPathComparator(\.duration)]
                    }
                    Button(tr("Date Added", "添加日期", zhHant: "加入日期")) {
                        sortOrder = [KeyPathComparator(\.addedAtSortValue)]
                    }
                    Button(tr("Plays", "播放次数", zhHant: "播放次數")) {
                        sortOrder = [KeyPathComparator(\.playCount)]
                    }
                } label: {
                    Label(tr("Sort songs", "歌曲排序", zhHant: "歌曲排序"), systemImage: "arrow.up.arrow.down")
                }
                .labelStyle(.iconOnly)
                .help(tr("Sort songs", "歌曲排序"))
                .fixedSize()
                if accessiblePageCount > 1 {
                    Button(tr("Previous page", "上一页", zhHant: "上一頁")) {
                        accessiblePage = max(0, accessiblePage - 1)
                        selection = []
                    }
                    .disabled(accessiblePage == 0)
                    Text(tr("Page \(accessiblePage + 1) of \(accessiblePageCount)",
                            "第 \(accessiblePage + 1) 页，共 \(accessiblePageCount) 页",
                            zhHant: "第 \(accessiblePage + 1) 頁，共 \(accessiblePageCount) 頁"))
                        .accessibilityAddTraits(.isStaticText)
                    Button(tr("Next page", "下一页", zhHant: "下一頁")) {
                        accessiblePage = min(accessiblePageCount - 1, accessiblePage + 1)
                        selection = []
                    }
                    .disabled(accessiblePage + 1 >= accessiblePageCount)
                }
            }
            .font(MusesTypography.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        if usesAccessiblePages {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tableRows) { row in
                        HStack(spacing: 12) {
                            Button { onPlay(row) } label: {
                                HStack(spacing: 12) {
                                    Text("\(row.canonicalIndex + 1)")
                                        .monospacedDigit()
                                        .foregroundStyle(BrandColors.textSecondary)
                                        .frame(width: 40, alignment: .trailing)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.title).font(MusesTypography.song(size: 14, emphasized: true, text: row.title)).lineLimit(1)
                                        Text(row.displayArtist).font(MusesTypography.song(size: 12, text: row.displayArtist))
                                            .foregroundStyle(BrandColors.textSecondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    Text(formatDuration(row.duration))
                                        .monospacedDigit()
                                        .foregroundStyle(BrandColors.textSecondary)
                                }
                                .frame(minHeight: 42)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.fullAreaPlain)
                            .accessibilityLabel(tr("Play \(row.title) by \(row.displayArtist)",
                                                   "播放 \(row.displayArtist) 的 \(row.title)",
                                                   zhHant: "播放 \(row.displayArtist) 的 \(row.title)"))
                            Button { library.toggleLike(snapshot: row.snapshot) } label: {
                                Image(systemName: likedIDs.contains(row.snapshot.id) ? "heart.fill" : "heart")
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.fullAreaPlain)
                            .accessibilityLabel(likedIDs.contains(row.snapshot.id)
                                ? tr("Unlike \(row.title)", "取消收藏 \(row.title)", zhHant: "取消喜愛 \(row.title)")
                                : tr("Like \(row.title)", "收藏 \(row.title)", zhHant: "喜愛 \(row.title)"))
                        }
                        .padding(.horizontal, 16)
                        .contextMenu { contextMenu(for: [row.id]) }
                        Divider()
                    }
                }
            }
            .background(BrandColors.background)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: OverlayChromeMetrics.scrollBottomInset)
            }
        } else {
            Table(
                tableRows,
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
                        liked: likedIDs.contains(row.snapshot.id),
                        isPlaying: matchesCurrent(row),
                        onPlay: { onPlay(row) },
                        onToggleLike: { library.toggleLike(snapshot: row.snapshot) },
                        onRemove: onRemove.map { handler in { handler(row) } }
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
                    secondaryText(row.displayArtist)
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
        }
        }
        .onAppear {
            if let saved = presentation {
                selection = saved.selection.intersection(Set(rows.map(\.id)))
                sortOrder = saved.sortOrder ?? defaultSort.comparators
                columnCustomization = saved.columns
            }
        }
        .onChange(of: selection) { _, value in presentation?.selection = value }
        .onChange(of: sortOrder) { _, value in
            accessiblePage = 0
            presentation?.sortOrder = value
            displayedRows = CollectionTrackSort.rows(rows, using: value)
        }
        .onChange(of: usesAccessiblePages) { _, _ in
            accessiblePage = 0
            selection = []
        }
        .onChange(of: rows, initial: true) { _, value in
            displayedRows = CollectionTrackSort.rows(value, using: sortOrder)
            accessiblePage = min(accessiblePage, accessiblePageCount - 1)
        }
        .onChange(of: columnCustomization) { _, value in presentation?.columns = value }
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
        if selectedIDs.count > 1, let onRemove {
            Button(role: .destructive) {
                displayedRows
                    .filter { selectedIDs.contains($0.id) }
                    .forEach(onRemove)
            } label: {
                Label(
                    tr("Remove \(selectedIDs.count) songs", "移除 \(selectedIDs.count) 首歌曲"),
                    systemImage: "minus.circle"
                )
            }
            Divider()
        }

        if let row = firstRow(in: selectedIDs) {
            TrackContextMenuItems(
                snapshot: row.snapshot,
                playlists: playlists,
                onPlay: { onPlay(row) },
                onRemoveFromContainer: onRemove.map { handler in { handler(row) } },
                onEditTrack: { editingTrack = library.track(by: row.snapshot.id) },
                onTrackNotes: { notesTrack = library.track(by: row.snapshot.id) },
                onCreatePlaylist: {
                    pendingNewPlaylistTrackID = row.snapshot.id
                    showCreatePlaylist = true
                }
            )
            .environment(playback)
            .environment(library)
            .environment(playlistService)
        }
    }

    private func firstRow(in selectedIDs: Set<UUID>) -> CollectionTrackRow? {
        displayedRows.first { selectedIDs.contains($0.id) }
    }

    private func refreshLikedIDs() {
        likedIDs = library.likedSnapshotIDs(for: rows.map(\.snapshot))
    }

    private func matchesCurrent(_ row: CollectionTrackRow) -> Bool {
        guard let currentTrack else { return false }
        return currentTrack.id == row.snapshot.id
            || (!currentTrack.youTubeId.isEmpty
                && currentTrack.youTubeId == row.snapshot.youTubeId)
    }

    private func secondaryText(_ value: String) -> some View {
        Text(value.isEmpty ? "—" : value)
            .font(MusesTypography.song(size: 12.5))
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
    let onRemove: (() -> Void)?

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
                            .font(MusesTypography.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.fullAreaPlain)
            .onHover { hoveringArtwork = $0 }
            .help(tr("Play \(row.title)", "播放 \(row.title)", zhHant: "播放 \(row.title)"))
            .accessibilityLabel(tr("Play \(row.title)", "播放 \(row.title)", zhHant: "播放 \(row.title)"))

            Text(row.title)
                .font(MusesTypography.song(size: 13, emphasized: isPlaying, text: row.title))
                .foregroundStyle(isPlaying ? BrandColors.accent : BrandColors.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button(action: onToggleLike) {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(MusesTypography.system(size: 12, weight: .semibold))
                    .foregroundStyle(liked ? BrandColors.accent : BrandColors.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.fullAreaPlain)
            .help(liked ? tr("Unlike", "取消收藏") : tr("Like", "收藏"))
            .accessibilityLabel(liked ? tr("Unlike \(row.title)", "取消收藏 \(row.title)", zhHant: "取消喜愛項目 \(row.title)")
                                      : tr("Like \(row.title)", "收藏 \(row.title)", zhHant: "喜愛項目 \(row.title)"))

            if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "minus.circle")
                        .font(MusesTypography.system(size: 12, weight: .semibold))
                        .foregroundStyle(BrandColors.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.fullAreaPlain)
                .help(tr("Remove \(row.title)", "移除 \(row.title)", zhHant: "移除 \(row.title)"))
                .accessibilityLabel(tr("Remove \(row.title)", "移除 \(row.title)", zhHant: "移除 \(row.title)"))
            }
        }
        .frame(minHeight: 42)
    }
}
