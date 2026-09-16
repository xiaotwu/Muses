import Foundation
import Observation
import SwiftData

/// Main-actor facade for rebuildable YouTube Music catalog projections.
/// It never invents identity from title or artist text.
@Observable
@MainActor
final class YouTubeCatalogService {
    private let modelContainer: ModelContainer
    private let bridge: (any YTDlpBridgeProtocol)?
    private(set) var revision = 0
    private var discographyCache: [String: (value: ArtistOnlineDiscography, date: Date)] = [:]
    private var albumTracksCache: [String: (value: [YTDlpBridge.YTDlpPlaylistEntry], date: Date)] = [:]

    init(modelContainer: ModelContainer, bridge: (any YTDlpBridgeProtocol)? = nil) {
        self.modelContainer = modelContainer
        self.bridge = bridge
    }

    /// Rebuild cache rows for all playable tracks from the library and playlists.
    /// Missing or legacy name identities remain unresolved; display names never group tracks.
    func rebuildFromTrackMetadata() {
        let context = ModelContext(modelContainer)
        let tracks = playableTracks(context: context)

        let releaseGroups = Dictionary(grouping: tracks.filter { YouTubeCatalogIdentity.isResolvedRelease($0.releaseCatalogID) },
                                       by: { $0.releaseCatalogID! })
        let existingReleases = (try? context.fetch(FetchDescriptor<CatalogRelease>())) ?? []
        let liveReleaseIDs = Set(releaseGroups.keys)
        for release in existingReleases where YouTubeCatalogIdentity.isResolvedRelease(release.stableID) && !liveReleaseIDs.contains(release.stableID) {
            // CatalogRelease is a rebuildable projection cache. Removing an
            // orphan row must never cascade into Track, Playlist, or history.
            context.delete(release)
        }
        let existingReleaseMap = Dictionary(uniqueKeysWithValues: existingReleases.map { ($0.stableID, $0) })
        for (stableID, members) in releaseGroups {
            guard let first = members.first else { continue }
            let releaseTitle = first.albumTitle ?? first.title
            let artistName = first.albumArtist ?? first.artist
            let artistStableIDs = Set(members.compactMap(\.artistCatalogID).filter { YouTubeCatalogIdentity.isResolvedArtist($0) })
            let artistStableID = artistStableIDs.count == 1 ? artistStableIDs.first : nil
            let artworkURL = first.artworkUrl ?? members.compactMap(\.artworkUrl).first
            let year = members.compactMap(\.year).first
            // A partial local collection and its display title do not establish release type.
            let kind: CatalogReleaseKind = .unknown

            if let existing = existingReleaseMap[stableID] {
                if existing.artworkURL == nil, let artworkURL { existing.artworkURL = artworkURL }
                if existing.artistStableID == nil, let artistStableID { existing.artistStableID = artistStableID }
                if existing.year == nil, let year { existing.year = year }
            } else {
                context.insert(CatalogRelease(
                    stableID: stableID,
                    title: releaseTitle,
                    artistName: artistName,
                    artistStableID: artistStableID,
                    artworkURL: artworkURL,
                    year: year,
                    kind: kind
                ))
            }
        }

        let artistGroups = Dictionary(grouping: tracks.filter { YouTubeCatalogIdentity.isResolvedArtist($0.artistCatalogID) },
                                      by: { $0.artistCatalogID! })
        let existingArtists = (try? context.fetch(FetchDescriptor<CatalogArtist>())) ?? []
        let liveArtistIDs = Set(artistGroups.keys)
        for artist in existingArtists where YouTubeCatalogIdentity.isResolvedArtist(artist.stableID) && !liveArtistIDs.contains(artist.stableID) {
            context.delete(artist)
        }
        let existingArtistMap = Dictionary(uniqueKeysWithValues: existingArtists.map { ($0.stableID, $0) })
        for (stableID, members) in artistGroups {
            guard let first = members.first else { continue }
            let rawArtist = first.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackArtist = (first.albumArtist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let artistName = !rawArtist.isEmpty ? rawArtist : (!fallbackArtist.isEmpty ? fallbackArtist : "Unknown Artist")
            let channelID = stableID.hasPrefix("channel:")
                ? String(stableID.dropFirst("channel:".count)) : nil
            let artworkURL = first.artworkUrl ?? members.compactMap(\.artworkUrl).first

            if let existing = existingArtistMap[stableID] {
                if existing.artworkURL == nil, let artworkURL { existing.artworkURL = artworkURL }
                if existing.channelID == nil, let channelID { existing.channelID = channelID }
            } else {
                context.insert(CatalogArtist(
                    stableID: stableID,
                    name: artistName,
                    channelID: channelID,
                    artworkURL: artworkURL
                ))
            }
        }
        try? context.save()
        revision &+= 1
    }

    func upsertArtist(stableID: String, name: String,
                      channelID: String? = nil, browseID: String? = nil,
                      artworkURL: String? = nil, biography: String? = nil,
                      refreshedAt: Date = .init(), unavailable: Bool = false) {
        guard YouTubeCatalogIdentity.isResolvedArtist(stableID) else { return }
        let context = ModelContext(modelContainer)
        let key = stableID
        let descriptor = FetchDescriptor<CatalogArtist>(predicate: #Predicate { $0.stableID == key })
        let row = (try? context.fetch(descriptor).first)
            ?? CatalogArtist(stableID: stableID, name: name)
        if row.modelContext == nil { context.insert(row) }
        row.name = name
        row.channelID = channelID
        row.browseID = browseID
        row.artworkURL = artworkURL
        row.biography = biography
        row.refreshedAt = refreshedAt
        row.unavailable = unavailable
        try? context.save()
        revision &+= 1
    }

    func upsertRelease(stableID: String, title: String, artistName: String,
                       artistStableID: String? = nil, artworkURL: String? = nil,
                       year: Int? = nil, kind: CatalogReleaseKind = .unknown,
                       refreshedAt: Date = .init(), unavailable: Bool = false) {
        guard YouTubeCatalogIdentity.isResolvedRelease(stableID) else { return }
        let context = ModelContext(modelContainer)
        let key = stableID
        let descriptor = FetchDescriptor<CatalogRelease>(predicate: #Predicate { $0.stableID == key })
        let row = (try? context.fetch(descriptor).first)
            ?? CatalogRelease(stableID: stableID, title: title, artistName: artistName)
        if row.modelContext == nil { context.insert(row) }
        row.title = title
        row.artistName = artistName
        row.artistStableID = artistStableID
        row.artworkURL = artworkURL
        row.year = year
        row.kind = kind
        row.refreshedAt = refreshedAt
        row.unavailable = unavailable
        try? context.save()
        revision &+= 1
    }

    func releases(now: Date = .init()) -> [CatalogReleaseProjection] {
        var context = ModelContext(modelContainer)
        var tracks = playableTracks(context: context)
        var releaseRows = (try? context.fetch(FetchDescriptor<CatalogRelease>())) ?? []
        if releaseRows.isEmpty && tracks.contains(where: { YouTubeCatalogIdentity.isResolvedRelease($0.releaseCatalogID) }) {
            rebuildFromTrackMetadata()
            context = ModelContext(modelContainer)
            tracks = playableTracks(context: context)
            releaseRows = (try? context.fetch(FetchDescriptor<CatalogRelease>())) ?? []
        }
        let grouped = Dictionary(grouping: tracks.compactMap { track -> Track? in
            guard YouTubeCatalogIdentity.isResolvedRelease(track.releaseCatalogID) else { return nil }
            return track
        }, by: { $0.releaseCatalogID! })

        return releaseRows.filter { YouTubeCatalogIdentity.isResolvedRelease($0.stableID) }.compactMap { row in
            let members = grouped[row.stableID] ?? []
            guard !members.isEmpty else { return nil }
            let ordered = members.sorted { lhs, rhs in
                let left = lhs.releaseOrder ?? .max
                let right = rhs.releaseOrder ?? .max
                if left != right { return left < right }
                let title = lhs.title.localizedStandardCompare(rhs.title)
                if title != .orderedSame { return title == .orderedAscending }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return CatalogReleaseProjection(
                stableID: row.stableID,
                title: row.title,
                artistName: row.artistName,
                artistStableID: row.artistStableID,
                artworkURL: row.artworkURL,
                year: row.year,
                kind: row.kind,
                cacheState: .resolve(refreshedAt: row.refreshedAt,
                                     unavailable: row.unavailable, now: now),
                tracks: ordered.map(TrackSnapshot.init(from:))
            )
        }
        .sorted {
            let result = $0.title.localizedStandardCompare($1.title)
            if result != .orderedSame { return result == .orderedAscending }
            return $0.stableID < $1.stableID
        }
    }

    func artists(now: Date = .init()) -> [CatalogArtistProjection] {
        var context = ModelContext(modelContainer)
        var tracks = playableTracks(context: context)
        var artistRows = (try? context.fetch(FetchDescriptor<CatalogArtist>())) ?? []
        if artistRows.isEmpty && tracks.contains(where: { YouTubeCatalogIdentity.isResolvedArtist($0.artistCatalogID) }) {
            rebuildFromTrackMetadata()
            context = ModelContext(modelContainer)
            tracks = playableTracks(context: context)
            artistRows = (try? context.fetch(FetchDescriptor<CatalogArtist>())) ?? []
        }
        let allReleases = releases(now: now)
        let grouped = Dictionary(grouping: tracks.compactMap { track -> Track? in
            guard YouTubeCatalogIdentity.isResolvedArtist(track.artistCatalogID) else { return nil }
            return track
        }, by: { $0.artistCatalogID! })

        return artistRows.filter { YouTubeCatalogIdentity.isResolvedArtist($0.stableID) }.map { row in
            let artistTracks = (grouped[row.stableID] ?? []).sorted {
                let result = $0.title.localizedStandardCompare($1.title)
                if result != .orderedSame { return result == .orderedAscending }
                return $0.id.uuidString < $1.id.uuidString
            }
            return CatalogArtistProjection(
                stableID: row.stableID,
                name: row.name,
                artworkURL: row.artworkURL,
                biography: row.biography,
                cacheState: .resolve(refreshedAt: row.refreshedAt,
                                     unavailable: row.unavailable, now: now),
                releases: allReleases.filter { $0.artistStableID == row.stableID },
                tracks: artistTracks.map(TrackSnapshot.init(from:))
            )
        }
        .sorted {
            let result = $0.name.localizedStandardCompare($1.name)
            if result != .orderedSame { return result == .orderedAscending }
            return $0.stableID < $1.stableID
        }
    }

    func release(byStableID id: String) -> CatalogReleaseProjection? {
        releases().first { $0.stableID == id }
    }

    func release(byTitle title: String) -> CatalogReleaseProjection? {
        let matches = releases().filter { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }
        return matches.count == 1 ? matches[0] : nil
    }

    func artist(byStableID id: String) -> CatalogArtistProjection? {
        artists().first { $0.stableID == id }
    }

    func artist(byName name: String) -> CatalogArtistProjection? {
        let matches = artists().filter { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        return matches.count == 1 ? matches[0] : nil
    }

    // MARK: - Online Discovery
    
    /// Search results only belong to an artist when their channel identity matches.
    func fetchArtistOnlineDiscography(artist: CatalogArtistProjection, forceRefresh: Bool = false) async throws -> ArtistOnlineDiscography {
        if !forceRefresh, let cached = discographyCache[artist.stableID], Date().timeIntervalSince(cached.date) < 900 {
            return cached.value
        }
        guard let bridge else { throw CatalogOnlineError.unavailable }
        let rawID = artist.stableID.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
        guard rawID.hasPrefix("UC"), YouTubeCatalogIdentity.isResolvedArtist(artist.stableID) else {
            throw CatalogOnlineError.unresolvedArtist
        }
        let query = "\(artist.name) official audio"
        if forceRefresh { bridge.invalidateSearch(query: query, limit: 24) }
        let results = try await bridge.searchYouTube(query: query, limit: 24, timeout: 30)
        try Task.checkCancellation()
        let tracks = results.filter { $0.resourceKind == .video && $0.channelID == rawID }
        // Do not turn title-matched videos or third-party playlists into official albums.
        let releases = results.filter {
            $0.resourceKind == .playlist && $0.channelID == rawID && YouTubePlaylistID.isMusicAlbum($0.id)
        }.map {
            OnlineReleaseItem(playlistID: $0.id, title: $0.title, artworkURL: nil,
                              year: $0.releaseYear, kind: .album, channelID: rawID)
        }
        let result = ArtistOnlineDiscography(artistName: artist.name, channelID: rawID,
                                             topTracks: tracks, albums: releases, singlesAndEPs: [])
        if discographyCache.count >= 100 { discographyCache.removeAll() }
        discographyCache[artist.stableID] = (result, Date())
        return result
    }

    func fetchAlbumOnlineTracks(release: CatalogReleaseProjection, forceRefresh: Bool = false) async throws -> [YTDlpBridge.YTDlpPlaylistEntry] {
        if !forceRefresh, let cached = albumTracksCache[release.stableID], Date().timeIntervalSince(cached.date) < 900 {
            return cached.value
        }
        guard let bridge else { throw CatalogOnlineError.unavailable }
        guard YouTubeCatalogIdentity.isResolvedRelease(release.stableID),
              let url = YouTubeCatalogLink.releaseURL(stableID: release.stableID) else {
            throw CatalogOnlineError.unresolvedRelease
        }
        let entries = try await bridge.fetchPlaylist(url: url.absoluteString, timeout: 40)
        try Task.checkCancellation()
        var seen = Set<String>()
        let tracks = entries.filter { $0.resourceKind == .video && seen.insert($0.id).inserted }
        if albumTracksCache.count >= 100 { albumTracksCache.removeAll() }
        albumTracksCache[release.stableID] = (tracks, Date())
        return tracks
    }

    /// Imports an online discovery track into the local library, attaching release and artist catalog IDs.
    @discardableResult
    func importOnlineTrack(
        entry: YTDlpBridge.YTDlpPlaylistEntry,
        releaseStableID: String? = nil,
        order: Int? = nil,
        albumTitle: String? = nil,
        artistName: String? = nil,
        saveToLibrary: Bool = true
    ) throws -> TrackSnapshot {
        guard entry.resourceKind == .video else { throw YouTubeImportError.invalidURL }
        if let releaseStableID, !YouTubeCatalogIdentity.isResolvedRelease(releaseStableID) {
            throw YouTubeImportError.invalidURL
        }
        let context = ModelContext(modelContainer)
        let videoID = entry.id
        let descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.youTubeId == videoID })
        let existing = try context.fetch(descriptor).first
        let track: Track

        if let existing {
            track = existing
            if saveToLibrary { track.libraryMember = true }
            if track.releaseCatalogID == nil, let releaseStableID {
                track.releaseCatalogID = releaseStableID
                track.releaseOrder = order
            }
            if track.albumTitle == nil, let albumTitle {
                track.albumTitle = albumTitle
            }
        } else {
            let durationMs = Int((entry.duration ?? 0) * 1000)
            let resolvedArtist = artistName ?? entry.uploader ?? "Unknown"
            let artistStableID = YouTubeCatalogIdentity.artist(
                channelID: entry.channelID, browseID: nil)
            track = Track(
                title: entry.title,
                artist: resolvedArtist,
                albumTitle: albumTitle ?? entry.album,
                albumArtist: resolvedArtist,
                durationMs: durationMs,
                youTubeId: entry.id,
                artworkUrl: YouTubeThumbnail.urlString(videoId: entry.id),
                mediaKind: entry.inferredMediaKind,
                releaseCatalogID: releaseStableID,
                releaseOrder: order,
                artistCatalogID: artistStableID,
                isInLibrary: saveToLibrary
            )
            context.insert(track)
            if let artistStableID {
                let key = artistStableID
                let artistDesc = FetchDescriptor<CatalogArtist>(predicate: #Predicate { $0.stableID == key })
                if (try? context.fetch(artistDesc).first) == nil {
                    context.insert(CatalogArtist(
                        stableID: artistStableID,
                        name: resolvedArtist,
                        channelID: entry.channelID
                    ))
                }
            }
        }
        try context.save()
        revision &+= 1
        return TrackSnapshot(from: track)
    }

    /// Imports an entire online release into the library.
    func importOnlineAlbum(
        release: OnlineReleaseItem,
        tracks: [YTDlpBridge.YTDlpPlaylistEntry],
        artistName: String?
    ) throws {
        guard YouTubeCatalogIdentity.isResolvedRelease(release.stableID),
              tracks.allSatisfy({ $0.resourceKind == .video }) else {
            throw YouTubeImportError.invalidURL
        }
        let context = ModelContext(modelContainer)
        let releaseStableID = release.stableID
        let albumTitle = release.title
        let artist = artistName ?? "Unknown"

        let relDesc = FetchDescriptor<CatalogRelease>(predicate: #Predicate { $0.stableID == releaseStableID })
        let existingRelease = (try? context.fetch(relDesc).first)
            ?? CatalogRelease(
                stableID: releaseStableID,
                title: albumTitle,
                artistName: artist,
                artistStableID: release.channelID.map { "channel:\($0)" },
                artworkURL: release.artworkURL,
                year: release.year,
                kind: release.kind
            )
        if existingRelease.modelContext == nil {
            context.insert(existingRelease)
        }

        for (index, entry) in tracks.enumerated() {
            let videoID = entry.id
            let descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.youTubeId == videoID })
            if let existingTrack = try? context.fetch(descriptor).first {
                existingTrack.libraryMember = true
                existingTrack.releaseCatalogID = releaseStableID
                existingTrack.releaseOrder = index
                if existingTrack.albumTitle == nil { existingTrack.albumTitle = albumTitle }
            } else {
                let track = Track(
                    title: entry.title,
                    artist: artist,
                    albumTitle: albumTitle,
                    albumArtist: artist,
                    durationMs: Int((entry.duration ?? 0) * 1000),
                    youTubeId: entry.id,
                    artworkUrl: YouTubeThumbnail.urlString(videoId: entry.id),
                    mediaKind: entry.inferredMediaKind,
                    releaseCatalogID: releaseStableID,
                    releaseOrder: index,
                    artistCatalogID: release.channelID.map { "channel:\($0)" }
                )
                context.insert(track)
            }
        }

        try context.save()
        rebuildFromTrackMetadata()
    }

    private func playableTracks(context: ModelContext) -> [Track] {
        ((try? context.fetch(FetchDescriptor<Track>())) ?? []).filter {
            $0.isInLibrary && !$0.youTubeId.isEmpty
        }
    }

    func unresolvedCounts() -> (releases: Int, artists: Int) {
        let tracks = playableTracks(context: ModelContext(modelContainer))
        return (tracks.filter { !YouTubeCatalogIdentity.isResolvedRelease($0.releaseCatalogID) }.count,
                tracks.filter { !YouTubeCatalogIdentity.isResolvedArtist($0.artistCatalogID) }.count)
    }
}

enum CatalogOnlineError: LocalizedError {
    case unavailable, unresolvedArtist, unresolvedRelease
    var errorDescription: String? {
        switch self {
        case .unavailable: return tr("Online catalog is unavailable. Try again later.", "在线目录暂不可用，请稍后重试。", zhHant: "線上目錄暫不可用，請稍後重試。")
        case .unresolvedArtist: return tr("A verified YouTube channel is required to load this artist’s catalog.", "需要已验证的 YouTube 频道才能加载此艺人的目录。", zhHant: "需要已驗證的 YouTube 頻道才能載入此藝人的目錄。")
        case .unresolvedRelease: return tr("This release has no verified YouTube album identity.", "此发行尚无已验证的 YouTube 专辑身份。", zhHant: "此發行尚無已驗證的 YouTube 專輯身分。")
        }
    }
}
