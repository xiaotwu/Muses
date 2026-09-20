import Foundation
import Observation
import SwiftData

/// Main-actor facade for rebuildable YouTube Music catalog projections.
/// It never invents identity from title or artist text.
@Observable
@MainActor
final class YouTubeCatalogService {
    private let modelContainer: ModelContainer
    private let structuredCatalog: any MusicCatalogProviding
    private(set) var revision = 0
    private var discographyCache: [String: (value: ArtistOnlineDiscography, date: Date)] = [:]
    private var albumTracksCache: [String: (value: [YTDlpBridge.YTDlpPlaylistEntry], date: Date)] = [:]

    init(
        modelContainer: ModelContainer,
        structuredCatalog: any MusicCatalogProviding = LocaleScopedMusicCatalogProvider()
    ) {
        self.modelContainer = modelContainer
        self.structuredCatalog = structuredCatalog
    }

    /// Rebuild cache rows for all playable tracks from the library and playlists.
    /// Missing or legacy name identities remain unresolved; display names never group tracks.
    func rebuildFromTrackMetadata() {
        let context = ModelContext(modelContainer)
        let tracks = playableTracks(context: context)

        let releaseGroups = releaseMembershipGroups(tracks: tracks, context: context)
        let existingReleases = (try? context.fetch(FetchDescriptor<CatalogRelease>())) ?? []
        let liveReleaseIDs = Set(releaseGroups.keys)
        for release in existingReleases where YouTubeCatalogIdentity.isResolvedRelease(release.stableID) && !liveReleaseIDs.contains(release.stableID) {
            // CatalogRelease is a rebuildable projection cache. Removing an
            // orphan row must never cascade into Track, Playlist, or history.
            context.delete(release)
        }
        let existingReleaseMap = Dictionary(uniqueKeysWithValues: existingReleases.map { ($0.stableID, $0) })
        for (stableID, members) in releaseGroups {
            guard let first = members.first?.track else { continue }
            let releaseTitle = first.albumTitle ?? first.title
            let artistName = first.albumArtist ?? first.artist
            let artistStableIDs = Set(members.compactMap(\.track.artistCatalogID).filter { YouTubeCatalogIdentity.isResolvedArtist($0) })
            let artistStableID = artistStableIDs.count == 1 ? artistStableIDs.first : nil
            let artworkURL = first.artworkUrl ?? members.compactMap(\.track.artworkUrl).first
            let year = members.compactMap(\.track.year).first
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
        var grouped = releaseMembershipGroups(tracks: tracks, context: context)
        if releaseRows.isEmpty && !grouped.isEmpty {
            rebuildFromTrackMetadata()
            context = ModelContext(modelContainer)
            tracks = playableTracks(context: context)
            releaseRows = (try? context.fetch(FetchDescriptor<CatalogRelease>())) ?? []
            grouped = releaseMembershipGroups(tracks: tracks, context: context)
        }

        return releaseRows.filter { YouTubeCatalogIdentity.isResolvedRelease($0.stableID) }.compactMap { row in
            let members = grouped[row.stableID] ?? []
            guard !members.isEmpty else { return nil }
            let ordered = members.sorted { lhs, rhs in
                let left = lhs.order ?? .max
                let right = rhs.order ?? .max
                if left != right { return left < right }
                let title = lhs.track.title.localizedStandardCompare(rhs.track.title)
                if title != .orderedSame { return title == .orderedAscending }
                return lhs.track.id.uuidString < rhs.track.id.uuidString
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
                tracks: ordered.map { TrackSnapshot(from: $0.track) }
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
    
    /// Reads the artist's stable browse/channel page. Display-name search and
    /// yt-dlp results never establish discography membership.
    func fetchArtistOnlineDiscography(artist: CatalogArtistProjection, forceRefresh: Bool = false) async throws -> ArtistOnlineDiscography {
        if !forceRefresh, let cached = discographyCache[artist.stableID], Date().timeIntervalSince(cached.date) < 900 {
            return cached.value
        }
        let rawID = artist.stableID.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
        guard rawID.hasPrefix("UC"), YouTubeCatalogIdentity.isResolvedArtist(artist.stableID) else {
            throw CatalogOnlineError.unresolvedArtist
        }
        if forceRefresh { await structuredCatalog.reset() }
        let items = try await completeBrowse("browse:\(rawID)")
        var seenTracks = Set<String>()
        let tracks = items.compactMap { item -> YTDlpBridge.YTDlpPlaylistEntry? in
            guard [.song, .video].contains(item.kind),
                  seenTracks.insert(item.id).inserted else { return nil }
            return catalogEntry(item, fallbackArtist: artist.name,
                                channelID: rawID)
        }
        var seenReleases = Set<String>()
        let releases = items.compactMap { item -> OnlineReleaseItem? in
            guard item.kind == .album,
                  YouTubeCatalogIdentity.isResolvedRelease(item.id),
                  seenReleases.insert(item.id).inserted else { return nil }
            return OnlineReleaseItem(
                stableID: item.id, title: item.title,
                artworkURL: item.artwork?.absoluteString,
                kind: .album, channelID: rawID)
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
        guard YouTubeCatalogIdentity.isResolvedRelease(release.stableID) else {
            throw CatalogOnlineError.unresolvedRelease
        }
        if forceRefresh { await structuredCatalog.reset() }
        let entries = try await completeBrowse(release.stableID)
            .compactMap {
                catalogEntry(
                    $0, fallbackArtist: release.artistName,
                    channelID: release.artistStableID?.split(
                        separator: ":", maxSplits: 1).last.map(String.init))
            }
        var seen = Set<String>()
        let tracks = entries.filter { seen.insert($0.id).inserted }
        if albumTracksCache.count >= 100 { albumTracksCache.removeAll() }
        albumTracksCache[release.stableID] = (tracks, Date())
        return tracks
    }

    private func completeBrowse(_ id: String) async throws
        -> [MusicCatalogItem] {
        var page = try await structuredCatalog.browse(id)
        var result = page.items + page.relatedItems
        var pageCount = 1
        while let cursor = page.next, pageCount < 20, result.count < 5_000 {
            try Task.checkCancellation()
            page = try await structuredCatalog.next(cursor)
            result += page.items
            result += page.relatedItems
            pageCount += 1
        }
        guard page.next == nil else { throw CatalogOnlineError.incomplete }
        return result
    }

    private func catalogEntry(
        _ item: MusicCatalogItem,
        fallbackArtist: String,
        channelID: String?
    ) -> YTDlpBridge.YTDlpPlaylistEntry? {
        guard [.song, .video].contains(item.kind),
              item.id.hasPrefix("video:") else { return nil }
        let videoID = String(item.id.dropFirst("video:".count))
        guard videoID.count == 11, MusicCatalogParser.validID(videoID) else {
            return nil
        }
        let artist = item.artists.map(\.title).joined(separator: ", ")
        return .init(
            id: videoID, title: item.title,
            uploader: artist.isEmpty ? fallbackArtist : artist,
            channelID: channelID,
            track: item.kind == .song ? item.title : nil,
            album: item.releases.first?.title)
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
        if let releaseStableID {
            try CatalogReleaseMembershipStore.upsert(
                track: track,
                releaseStableID: releaseStableID,
                releaseOrder: order,
                evidenceKind: .catalogBrowse,
                context: context)
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
                if existingTrack.albumTitle == nil { existingTrack.albumTitle = albumTitle }
                try CatalogReleaseMembershipStore.upsert(
                    track: existingTrack,
                    releaseStableID: releaseStableID,
                    releaseOrder: index,
                    evidenceKind: .catalogBrowse,
                    context: context)
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
                try CatalogReleaseMembershipStore.upsert(
                    track: track,
                    releaseStableID: releaseStableID,
                    releaseOrder: index,
                    evidenceKind: .catalogBrowse,
                    context: context)
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
        let context = ModelContext(modelContainer)
        let tracks = playableTracks(context: context)
        let resolvedTrackIDs = Set(releaseMembershipGroups(
            tracks: tracks, context: context).values.flatMap { $0.map(\.track.id) })
        return (tracks.filter { !resolvedTrackIDs.contains($0.id) }.count,
                tracks.filter { !YouTubeCatalogIdentity.isResolvedArtist($0.artistCatalogID) }.count)
    }

    private struct ReleaseMember {
        let track: Track
        let order: Int?
    }

    private struct ReleaseTrackKey: Hashable {
        let releaseID: String
        let trackID: UUID
    }

    /// Persisted source edges are authoritative. Legacy single-value fields
    /// contribute only in-memory compatibility edges and are never written by
    /// a rebuild.
    private func releaseMembershipGroups(
        tracks: [Track], context: ModelContext
    ) -> [String: [ReleaseMember]] {
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let values = (try? CatalogReleaseMembershipStore.values(
            for: tracks, in: context)) ?? []
        var members: [ReleaseTrackKey: ReleaseMember] = [:]
        for value in values {
            guard YouTubeCatalogIdentity.isResolvedRelease(value.releaseStableID),
                  let track = byID[value.trackID] else { continue }
            let key = ReleaseTrackKey(
                releaseID: value.releaseStableID, trackID: value.trackID)
            if let existing = members[key] {
                let oldOrder = existing.order ?? .max
                let newOrder = value.releaseOrder ?? .max
                if newOrder < oldOrder {
                    members[key] = ReleaseMember(
                        track: track, order: value.releaseOrder)
                }
            } else {
                members[key] = ReleaseMember(
                    track: track, order: value.releaseOrder)
            }
        }
        return Dictionary(grouping: members) { $0.key.releaseID }
            .mapValues { $0.map(\.value) }
    }
}

enum CatalogOnlineError: LocalizedError {
    case unavailable, unresolvedArtist, unresolvedRelease, incomplete
    var errorDescription: String? {
        switch self {
        case .unavailable: return tr("Online catalog is unavailable. Try again later.", "在线目录暂不可用，请稍后重试。", zhHant: "線上目錄暫不可用，請稍後重試。")
        case .unresolvedArtist: return tr("A verified YouTube channel is required to load this artist’s catalog.", "需要已验证的 YouTube 频道才能加载此艺人的目录。", zhHant: "需要已驗證的 YouTube 頻道才能載入此藝人的目錄。")
        case .unresolvedRelease: return tr("This release has no verified YouTube album identity.", "此发行尚无已验证的 YouTube 专辑身份。", zhHant: "此發行尚無已驗證的 YouTube 專輯身分。")
        case .incomplete: return tr("The complete catalog could not be verified. Try again.", "无法确认完整目录，请重试。", zhHant: "無法確認完整目錄，請再試一次。")
        }
    }
}
