import Foundation
import Observation
import SwiftData

/// Main-actor facade for rebuildable YouTube Music catalog projections.
/// It never invents identity from title or artist text.
@Observable
@MainActor
final class YouTubeCatalogService {
    private let modelContainer: ModelContainer
    private(set) var revision = 0

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Rebuild cache rows only when a Track already carries a stable catalog ID.
    /// Human-readable metadata fills presentation fields but never creates identity.
    func rebuildFromTrackMetadata() {
        let context = ModelContext(modelContainer)
        let tracks = playableTracks(context: context)
        let releaseGroups = Dictionary(grouping: tracks.filter { $0.releaseCatalogID != nil },
                                       by: { $0.releaseCatalogID! })
        let existingReleases = (try? context.fetch(FetchDescriptor<CatalogRelease>())) ?? []
        let liveReleaseIDs = Set(releaseGroups.keys)
        for release in existingReleases where !liveReleaseIDs.contains(release.stableID) {
            // CatalogRelease is a rebuildable projection cache. Removing an
            // orphan row must never cascade into Track, Playlist, or history.
            context.delete(release)
        }
        let releaseIDs = Set(existingReleases.map(\.stableID))
        for (stableID, members) in releaseGroups where !releaseIDs.contains(stableID) {
            guard let first = members.first else { continue }
            context.insert(CatalogRelease(
                stableID: stableID,
                title: first.albumTitle ?? first.title,
                artistName: first.albumArtist ?? first.artist,
                artistStableID: members.compactMap(\.artistCatalogID).first,
                artworkURL: first.artworkUrl,
                year: members.compactMap(\.year).first
            ))
        }
        let artistGroups = Dictionary(grouping: tracks.filter { $0.artistCatalogID != nil },
                                      by: { $0.artistCatalogID! })
        let existingArtists = (try? context.fetch(FetchDescriptor<CatalogArtist>())) ?? []
        let artistIDs = Set(existingArtists.map(\.stableID))
        for (stableID, members) in artistGroups where !artistIDs.contains(stableID) {
            guard let first = members.first else { continue }
            let channelID = stableID.hasPrefix("channel:")
                ? String(stableID.dropFirst("channel:".count)) : nil
            context.insert(CatalogArtist(stableID: stableID, name: first.artist,
                                         channelID: channelID,
                                         artworkURL: first.artworkUrl))
        }
        try? context.save()
        revision &+= 1
    }

    func upsertArtist(stableID: String, name: String,
                      channelID: String? = nil, browseID: String? = nil,
                      artworkURL: String? = nil, biography: String? = nil,
                      refreshedAt: Date = .init(), unavailable: Bool = false) {
        guard Self.validStableID(stableID, prefixes: ["channel:", "browse:"]) else { return }
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
        guard Self.validStableID(stableID, prefixes: ["browse:", "playlist:"]) else { return }
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
        let context = ModelContext(modelContainer)
        let releaseRows = (try? context.fetch(FetchDescriptor<CatalogRelease>())) ?? []
        let tracks = playableTracks(context: context)
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
        let context = ModelContext(modelContainer)
        let artistRows = (try? context.fetch(FetchDescriptor<CatalogArtist>())) ?? []
        let allReleases = releases(now: now)
        let tracks = playableTracks(context: context)
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

    private func playableTracks(context: ModelContext) -> [Track] {
        ((try? context.fetch(FetchDescriptor<Track>())) ?? []).filter {
            !$0.youTubeId.isEmpty
        }
    }

    private static func validStableID(_ value: String, prefixes: [String]) -> Bool {
        prefixes.contains { value.hasPrefix($0) && value.count > $0.count }
    }
}
