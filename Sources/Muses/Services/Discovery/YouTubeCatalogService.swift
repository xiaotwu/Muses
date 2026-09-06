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
    private var discographyCache: [String: ArtistOnlineDiscography] = [:]
    private var albumTracksCache: [String: [YTDlpBridge.YTDlpPlaylistEntry]] = [:]

    init(modelContainer: ModelContainer, bridge: (any YTDlpBridgeProtocol)? = nil) {
        self.modelContainer = modelContainer
        self.bridge = bridge
    }

    /// Rebuild cache rows for all playable tracks from the library and playlists.
    /// Derives stable catalog identity when missing so all library items appear in Albums and Artists.
    func rebuildFromTrackMetadata() {
        let context = ModelContext(modelContainer)
        ensureTracksForImportItems(context: context)
        let tracks = playableTracks(context: context)

        let allImports = (try? context.fetch(FetchDescriptor<YouTubeImport>())) ?? []
        var trackToImportMap: [UUID: YouTubeImport] = [:]
        for imp in allImports {
            for item in imp.items ?? [] {
                if let t = item.track, trackToImportMap[t.id] == nil {
                    trackToImportMap[t.id] = imp
                }
            }
        }

        var didModifyTracks = false
        for track in tracks {
            // Clean up: if releaseCatalogID was previously assigned to a non-album playlist, clear it!
            if let relID = track.releaseCatalogID, relID.hasPrefix("playlist:") {
                let pid = String(relID.dropFirst("playlist:".count))
                if !YouTubePlaylistID.isMusicAlbum(pid) {
                    track.releaseCatalogID = nil
                    if let imp = trackToImportMap[track.id], track.albumTitle == imp.title {
                        track.albumTitle = nil
                    }
                    if let imp = trackToImportMap[track.id], track.albumArtist == imp.channel {
                        track.albumArtist = nil
                    }
                    didModifyTracks = true
                }
            }

            let rawArtist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackArtist = (track.albumArtist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanArtist = !rawArtist.isEmpty ? rawArtist : (!fallbackArtist.isEmpty ? fallbackArtist : "Unknown Artist")

            if track.artistCatalogID == nil {
                track.artistCatalogID = "artist:\(cleanArtist.lowercased())"
                didModifyTracks = true
            }

            if track.releaseCatalogID == nil {
                let artistKey = cleanArtist.lowercased()
                if let albumTitle = track.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !albumTitle.isEmpty {
                    track.releaseCatalogID = "album:\(artistKey):\(albumTitle.lowercased())"
                    didModifyTracks = true
                } else if let imp = trackToImportMap[track.id] ?? track.youTubeImportItems?.compactMap(\.import_).first,
                          YouTubePlaylistID.isMusicAlbum(imp.playlistId),
                          !imp.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let impTitle = imp.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    track.releaseCatalogID = "playlist:\(imp.playlistId)"
                    if track.albumTitle == nil || track.albumTitle?.isEmpty == true {
                        track.albumTitle = impTitle
                    }
                    if track.albumArtist == nil || track.albumArtist?.isEmpty == true {
                        track.albumArtist = imp.channel
                    }
                    didModifyTracks = true
                } else {
                    track.releaseCatalogID = "single:\(track.youTubeId)"
                    if track.albumTitle == nil || track.albumTitle?.isEmpty == true {
                        track.albumTitle = track.title
                    }
                    didModifyTracks = true
                }
            }
        }

        if didModifyTracks {
            try? context.save()
        }

        let releaseGroups = Dictionary(grouping: tracks.filter { $0.releaseCatalogID != nil },
                                       by: { $0.releaseCatalogID! })
        let existingReleases = (try? context.fetch(FetchDescriptor<CatalogRelease>())) ?? []
        let liveReleaseIDs = Set(releaseGroups.keys)
        for release in existingReleases where !liveReleaseIDs.contains(release.stableID) {
            // CatalogRelease is a rebuildable projection cache. Removing an
            // orphan row must never cascade into Track, Playlist, or history.
            context.delete(release)
        }
        let existingReleaseMap = Dictionary(uniqueKeysWithValues: existingReleases.map { ($0.stableID, $0) })
        for (stableID, members) in releaseGroups {
            guard let first = members.first else { continue }
            let releaseTitle = first.albumTitle ?? first.title
            let artistName = first.albumArtist ?? first.artist
            let artistStableIDs = Set(members.compactMap(\.artistCatalogID))
            let artistStableID = artistStableIDs.count == 1 ? artistStableIDs.first : nil
            let artworkURL = first.artworkUrl ?? members.compactMap(\.artworkUrl).first
            let year = members.compactMap(\.year).first
            let kind: CatalogReleaseKind = {
                if stableID.hasPrefix("single:") { return .single }
                let tLower = releaseTitle.lowercased()
                if tLower.contains(" - single") || tLower.contains("(single)") { return .single }
                if tLower.contains(" - ep") || tLower.contains("(ep)") { return .ep }
                if members.count == 1 && (first.albumTitle == nil || first.albumTitle == first.title) {
                    return .single
                }
                return .album
            }()

            if let existing = existingReleaseMap[stableID] {
                if existing.artworkURL == nil, let artworkURL { existing.artworkURL = artworkURL }
                if existing.artistStableID == nil, let artistStableID { existing.artistStableID = artistStableID }
                if existing.year == nil, let year { existing.year = year }
                if existing.kind == .unknown { existing.kind = kind }
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

        let artistGroups = Dictionary(grouping: tracks.filter { $0.artistCatalogID != nil },
                                      by: { $0.artistCatalogID! })
        let existingArtists = (try? context.fetch(FetchDescriptor<CatalogArtist>())) ?? []
        let liveArtistIDs = Set(artistGroups.keys)
        for artist in existingArtists where !liveArtistIDs.contains(artist.stableID) {
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
        guard Self.validStableID(stableID, prefixes: ["channel:", "browse:", "artist:"]) else { return }
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
        guard Self.validStableID(stableID, prefixes: ["browse:", "playlist:", "album:", "single:"]) else { return }
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
        let hasInvalidPlaylistReleases = tracks.contains { track in
            guard let relID = track.releaseCatalogID, relID.hasPrefix("playlist:") else { return false }
            let pid = String(relID.dropFirst("playlist:".count))
            return !YouTubePlaylistID.isMusicAlbum(pid)
        }
        let uncataloged = tracks.contains { $0.releaseCatalogID == nil }
        if (releaseRows.isEmpty && !tracks.isEmpty) || uncataloged || hasInvalidPlaylistReleases {
            rebuildFromTrackMetadata()
            context = ModelContext(modelContainer)
            tracks = playableTracks(context: context)
            releaseRows = (try? context.fetch(FetchDescriptor<CatalogRelease>())) ?? []
        }
        let grouped = Dictionary(grouping: tracks.compactMap { track -> Track? in
            guard track.releaseCatalogID != nil else { return nil }
            return track
        }, by: { $0.releaseCatalogID! })

        return releaseRows.compactMap { row in
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
        let uncataloged = tracks.contains { $0.artistCatalogID == nil }
        if (artistRows.isEmpty && !tracks.isEmpty) || uncataloged {
            rebuildFromTrackMetadata()
            context = ModelContext(modelContainer)
            tracks = playableTracks(context: context)
            artistRows = (try? context.fetch(FetchDescriptor<CatalogArtist>())) ?? []
        }
        let allReleases = releases(now: now)
        let grouped = Dictionary(grouping: tracks.compactMap { track -> Track? in
            guard track.artistCatalogID != nil else { return nil }
            return track
        }, by: { $0.artistCatalogID! })

        return artistRows.map { row in
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
        releases().first { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }
    }

    func artist(byStableID id: String) -> CatalogArtistProjection? {
        artists().first { $0.stableID == id }
    }

    func artist(byName name: String) -> CatalogArtistProjection? {
        artists().first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - Online Discovery
    
    /// Fetches online discography (top songs, releases, singles) for an artist using yt-dlp.
    func fetchArtistOnlineDiscography(artist: CatalogArtistProjection) async throws -> ArtistOnlineDiscography {
        if let cached = discographyCache[artist.stableID] {
            return cached
        }
        guard let bridge else {
            return ArtistOnlineDiscography(artistName: artist.name)
        }

        let channelID: String? = {
            if artist.stableID.hasPrefix("channel:") {
                return String(artist.stableID.dropFirst("channel:".count))
            }
            return nil
        }()

        let topSongs: [YTDlpBridge.YTDlpPlaylistEntry] = (try? await bridge.searchYouTube(
            query: "\(artist.name) official audio",
            limit: 12,
            timeout: 25
        )) ?? []

        var rawReleases: [YTDlpBridge.YTDlpPlaylistEntry] = []
        if let channelID {
            let releasesURL = "https://www.youtube.com/channel/\(channelID)/releases"
            if let entries = try? await bridge.fetchPlaylist(url: releasesURL, timeout: 35),
               !entries.isEmpty {
                rawReleases = entries
            }
        }
        if rawReleases.isEmpty {
            rawReleases = (try? await bridge.searchYouTube(
                query: "\(artist.name) album",
                limit: 12,
                timeout: 25
            )) ?? []
        }

        var albums: [OnlineReleaseItem] = []
        var singlesAndEPs: [OnlineReleaseItem] = []

        for entry in rawReleases {
            let titleLower = entry.title.lowercased()
            let isSingleOrEP = titleLower.contains(" - single")
                || titleLower.contains(" - ep")
                || titleLower.contains("(single)")
                || titleLower.contains("(ep)")
                || titleLower.contains("remix")
            let kind: CatalogReleaseKind = isSingleOrEP ? .single : .album
            let item = OnlineReleaseItem(
                playlistID: entry.id,
                title: entry.title,
                artworkURL: YouTubeThumbnail.urlString(videoId: entry.id),
                year: entry.releaseYear,
                kind: kind,
                channelID: channelID ?? entry.channelID
            )
            if isSingleOrEP {
                singlesAndEPs.append(item)
            } else {
                albums.append(item)
            }
        }

        let discography = ArtistOnlineDiscography(
            artistName: artist.name,
            channelID: channelID,
            topTracks: topSongs,
            albums: albums,
            singlesAndEPs: singlesAndEPs
        )
        discographyCache[artist.stableID] = discography
        return discography
    }

    /// Fetches the full official tracklist for a release from YouTube Music.
    func fetchAlbumOnlineTracks(release: CatalogReleaseProjection) async throws -> [YTDlpBridge.YTDlpPlaylistEntry] {
        if let cached = albumTracksCache[release.stableID] {
            return cached
        }
        guard let bridge else { return [] }

        let targetURL: String? = {
            if release.stableID.hasPrefix("playlist:") {
                let pid = String(release.stableID.dropFirst("playlist:".count))
                return "https://www.youtube.com/playlist?list=\(pid)"
            } else if release.stableID.hasPrefix("browse:") {
                let bid = String(release.stableID.dropFirst("browse:".count))
                return "https://music.youtube.com/browse/\(bid)"
            }
            return nil
        }()

        if let url = targetURL {
            let entries = try await bridge.fetchPlaylist(url: url, timeout: 40)
            albumTracksCache[release.stableID] = entries
            return entries
        } else {
            let query = "\(release.artistName) \(release.title)"
            let entries = (try? await bridge.searchYouTube(
                query: query,
                limit: 20,
                timeout: 30
            )) ?? []
            albumTracksCache[release.stableID] = entries
            return entries
        }
    }

    /// Imports an online discovery track into the local library, attaching release and artist catalog IDs.
    @discardableResult
    func importOnlineTrack(
        entry: YTDlpBridge.YTDlpPlaylistEntry,
        releaseStableID: String? = nil,
        order: Int? = nil,
        albumTitle: String? = nil,
        artistName: String? = nil
    ) throws -> TrackSnapshot {
        let context = ModelContext(modelContainer)
        let videoID = entry.id
        let descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.youTubeId == videoID })
        let existing = try context.fetch(descriptor).first
        let track: Track

        if let existing {
            track = existing
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
                artistCatalogID: artistStableID
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
            !$0.youTubeId.isEmpty
        }
    }

    private func ensureTracksForImportItems(context: ModelContext) {
        let imports = (try? context.fetch(FetchDescriptor<YouTubeImport>())) ?? []
        var didInsert = false
        for imp in imports {
            for item in imp.items ?? [] {
                if item.track == nil && !item.youTubeId.isEmpty {
                    let vid = item.youTubeId
                    let descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.youTubeId == vid })
                    let existing = try? context.fetch(descriptor).first
                    if let existing {
                        item.track = existing
                    } else {
                        let isMusicAlbum = YouTubePlaylistID.isMusicAlbum(imp.playlistId)
                        let t = Track(
                            title: item.title,
                            artist: item.artist,
                            albumTitle: isMusicAlbum ? imp.title : nil,
                            albumArtist: isMusicAlbum ? imp.channel : nil,
                            durationMs: item.durationMs,
                            youTubeId: item.youTubeId,
                            artworkUrl: YouTubeThumbnail.urlString(videoId: item.youTubeId)
                        )
                        context.insert(t)
                        item.track = t
                        didInsert = true
                    }
                }
            }
        }
        if didInsert {
            try? context.save()
        }
    }

    private static func validStableID(_ value: String, prefixes: [String]) -> Bool {
        prefixes.contains { value.hasPrefix($0) && value.count > $0.count }
    }
}
