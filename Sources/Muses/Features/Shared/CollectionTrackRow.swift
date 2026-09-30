import Foundation

/// Immutable presentation value used by collection hero decks and track tables.
/// The canonical index belongs to the collection; visual table sorting never mutates it.
struct CollectionTrackRow: Identifiable, Equatable, Sendable {
    let snapshot: TrackSnapshot
    let canonicalIndex: Int
    let year: Int?
    let genre: String?
    let addedAt: Date?
    let playCount: Int
    let trackNumber: Int?
    let discNumber: Int?
    /// Collection occurrence identity. A playlist may contain the same Track
    /// more than once, so row identity cannot always equal media identity.
    let collectionItemID: UUID?
    let collectionOwner: String?
    let collectionTitle: String?

    var id: UUID { collectionItemID ?? snapshot.id }
    var title: String { snapshot.title }
    var artist: String {
        snapshot.artist.isEmpty || snapshot.artist == collectionOwner
            ? tr("Artist unavailable", "艺人信息暂缺") : snapshot.artist
    }
    var album: String {
        snapshot.albumTitle == collectionTitle ? "" : (snapshot.albumTitle ?? "")
    }
    var duration: Double { snapshot.durationSeconds }

    func matches(_ currentTrack: TrackSnapshot?) -> Bool {
        guard let currentTrack else { return false }
        return currentTrack.id == snapshot.id
            || (!currentTrack.youTubeId.isEmpty
                && currentTrack.youTubeId == snapshot.youTubeId)
    }

    // Non-optional projections keep every visible Table column natively sortable.
    var yearSortValue: Int { year ?? 0 }
    var genreSortValue: String { genre ?? "" }
    var addedAtSortValue: Date { addedAt ?? .distantPast }

    init(
        snapshot: TrackSnapshot,
        canonicalIndex: Int,
        year: Int? = nil,
        genre: String? = nil,
        addedAt: Date? = nil,
        playCount: Int = 0,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        collectionItemID: UUID? = nil,
        collectionOwner: String? = nil,
        collectionTitle: String? = nil
    ) {
        self.snapshot = snapshot
        self.canonicalIndex = canonicalIndex
        self.year = year
        self.genre = genre
        self.addedAt = addedAt
        self.playCount = playCount
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.collectionItemID = collectionItemID
        self.collectionOwner = collectionOwner
        self.collectionTitle = collectionTitle
    }

    @MainActor
    init(track: Track, canonicalIndex: Int, collectionItemID: UUID? = nil,
         collectionOwner: String? = nil, collectionTitle: String? = nil) {
        self.init(
            snapshot: TrackSnapshot(from: track),
            canonicalIndex: canonicalIndex,
            year: track.year,
            genre: track.genre,
            addedAt: track.addedAt,
            playCount: track.playCount,
            trackNumber: track.trackNo,
            discNumber: track.discNo,
            collectionItemID: collectionItemID,
            collectionOwner: collectionOwner,
            collectionTitle: collectionTitle
        )
    }

    /// Songs is an implicit collection whose canonical order is title A-Z.
    /// Artist, album, and stable ID break equal-title ties deterministically.
    @MainActor
    static func songs(from tracks: [Track]) -> [CollectionTrackRow] {
        tracks
            .filter { !$0.youTubeId.isEmpty }
            .sorted(by: songsAscending)
            .enumerated()
            .map { CollectionTrackRow(track: $0.element, canonicalIndex: $0.offset) }
    }

    /// Songs is the union of active playlist memberships, including imported
    /// items that have not yet materialized a Track. Deduplicate by video ID.
    @MainActor
    static func playlistUnion(playlists: [Playlist], imports: [YouTubeImport]) -> [CollectionTrackRow] {
        var unique: [String: CollectionTrackRow] = [:]
        for playlist in playlists.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            for row in Self.playlist(from: playlist.items ?? []) {
                unique[row.snapshot.youTubeId] = CollectionTrackRow(
                    snapshot: row.snapshot, canonicalIndex: 0, year: row.year,
                    genre: row.genre, addedAt: row.addedAt, playCount: row.playCount)
            }
        }
        for imported in imports.filter({ $0.deletedAt == nil })
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            for item in (imported.items ?? []).sorted(by: { $0.order < $1.order }) {
                guard !item.youTubeId.isEmpty, unique[item.youTubeId] == nil else { continue }
                let snapshot = item.track.map { TrackSnapshot(from: $0) } ?? TrackSnapshot(
                    id: item.id, title: item.title, artist: item.artist,
                    albumTitle: nil, durationSeconds: Double(item.durationMs) / 1000,
                    youTubeId: item.youTubeId,
                    artworkUrl: YouTubeThumbnail.urlString(videoId: item.youTubeId),
                    sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false)
                unique[item.youTubeId] = CollectionTrackRow(snapshot: snapshot,
                    canonicalIndex: 0, addedAt: imported.importedAt,
                    collectionOwner: imported.channel,
                    collectionTitle: YouTubePlaylistID.isMusicAlbum(imported.playlistId) ? nil : imported.title)
            }
        }
        return unique.values.sorted {
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            let artistOrder = $0.artist.localizedStandardCompare($1.artist)
            if artistOrder != .orderedSame { return artistOrder == .orderedAscending }
            return $0.snapshot.youTubeId < $1.snapshot.youTubeId
        }.enumerated().map { index, row in
            CollectionTrackRow(snapshot: row.snapshot, canonicalIndex: index,
                year: row.year, genre: row.genre, addedAt: row.addedAt, playCount: row.playCount,
                collectionOwner: row.collectionOwner, collectionTitle: row.collectionTitle)
        }
    }

    /// User playlists keep the explicit persisted PlaylistItem order.
    @MainActor
    static func playlist(from items: [PlaylistItem]) -> [CollectionTrackRow] {
        items
            .sorted {
                if $0.order != $1.order { return $0.order < $1.order }
                return $0.id.uuidString < $1.id.uuidString
            }
            .compactMap { item in
                guard let track = item.track, !track.youTubeId.isEmpty else { return nil }
                return CollectionTrackRow(track: track, canonicalIndex: item.order,
                                          collectionItemID: item.id)
            }
    }

    @MainActor
    private static func songsAscending(_ lhs: Track, _ rhs: Track) -> Bool {
        let title = lhs.title.localizedStandardCompare(rhs.title)
        if title != .orderedSame { return title == .orderedAscending }

        let artist = lhs.artist.localizedStandardCompare(rhs.artist)
        if artist != .orderedSame { return artist == .orderedAscending }

        let album = (lhs.albumTitle ?? "").localizedStandardCompare(rhs.albumTitle ?? "")
        if album != .orderedSame { return album == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

enum CollectionTableDefaultSort: Equatable, Sendable {
    case titleAZ
    case playlistOrder

    var comparators: [KeyPathComparator<CollectionTrackRow>] {
        switch self {
        case .titleAZ:
            [KeyPathComparator(\CollectionTrackRow.title, comparator: .localizedStandard)]
        case .playlistOrder:
            [KeyPathComparator(\CollectionTrackRow.canonicalIndex)]
        }
    }
}

enum CollectionTrackSort {
    static func rows(
        _ rows: [CollectionTrackRow],
        using comparators: [KeyPathComparator<CollectionTrackRow>]
    ) -> [CollectionTrackRow] {
        guard !comparators.isEmpty else { return rows }
        return rows.sorted(using: comparators)
    }
}

enum CollectionTablePaging {
    static func pageCount(rowCount: Int, pageSize: Int) -> Int {
        guard pageSize > 0 else { return 1 }
        return max(1, (rowCount + pageSize - 1) / pageSize)
    }

    static func rows(_ rows: [CollectionTrackRow], page: Int,
                     pageSize: Int) -> [CollectionTrackRow] {
        guard pageSize > 0 else { return rows }
        let clampedPage = min(max(0, page), pageCount(rowCount: rows.count,
                                                     pageSize: pageSize) - 1)
        return Array(rows.dropFirst(clampedPage * pageSize).prefix(pageSize))
    }
}
