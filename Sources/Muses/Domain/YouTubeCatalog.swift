import Foundation
import SwiftData

/// Stable identity construction for YouTube Music catalog entities.
/// Display names are deliberately absent from this API.
enum YouTubeCatalogIdentity {
    static func isResolvedRelease(_ value: String?) -> Bool {
        guard let value else { return false }
        if value.hasPrefix("browse:") { return validKey(value, prefix: "browse:") }
        if value.hasPrefix("playlist:") {
            return validKey(value, prefix: "playlist:") && YouTubePlaylistID.isMusicAlbum(String(value.dropFirst(9)))
        }
        return false
    }

    static func isResolvedArtist(_ value: String?) -> Bool {
        guard let value else { return false }
        return validKey(value, prefix: "channel:") || validKey(value, prefix: "browse:")
    }

    private static func validKey(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        let key = value.dropFirst(prefix.count)
        return !key.isEmpty && key.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func release(browseID: String?, playlistID: String?) -> String? {
        if let value = normalized(browseID) { return "browse:\(value)" }
        if let value = normalized(playlistID) { return "playlist:\(value)" }
        return nil
    }

    static func artist(channelID: String?, browseID: String?) -> String? {
        if let value = normalized(channelID) { return "channel:\(value)" }
        if let value = normalized(browseID) { return "browse:\(value)" }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum CatalogReleaseKind: String, Codable, Sendable, CaseIterable {
    case album
    case single
    case ep
    case unknown
}

/// Rebuildable release cache. User-owned state stays on Track/Playlist/history;
/// deleting this row must never delete a playable track.
@Model
final class CatalogRelease {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var stableID: String
    var title: String
    var artistName: String
    var artistStableID: String?
    var artworkURL: String?
    var year: Int?
    var kindRaw: String
    var refreshedAt: Date
    var unavailable: Bool

    init(id: UUID = UUID(), stableID: String, title: String, artistName: String,
         artistStableID: String? = nil, artworkURL: String? = nil, year: Int? = nil,
         kind: CatalogReleaseKind = .unknown, refreshedAt: Date = .init(),
         unavailable: Bool = false) {
        self.id = id
        self.stableID = stableID
        self.title = title
        self.artistName = artistName
        self.artistStableID = artistStableID
        self.artworkURL = artworkURL
        self.year = year
        self.kindRaw = kind.rawValue
        self.refreshedAt = refreshedAt
        self.unavailable = unavailable
    }

    var kind: CatalogReleaseKind {
        get { CatalogReleaseKind(rawValue: kindRaw) ?? .unknown }
        set { kindRaw = newValue.rawValue }
    }
}

/// Rebuildable artist cache keyed only by a YouTube channel or Music browse ID.
@Model
final class CatalogArtist {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var stableID: String
    var name: String
    var channelID: String?
    var browseID: String?
    var artworkURL: String?
    var biography: String?
    var refreshedAt: Date
    var unavailable: Bool

    init(id: UUID = UUID(), stableID: String, name: String,
         channelID: String? = nil, browseID: String? = nil,
         artworkURL: String? = nil, biography: String? = nil,
         refreshedAt: Date = .init(), unavailable: Bool = false) {
        self.id = id
        self.stableID = stableID
        self.name = name
        self.channelID = channelID
        self.browseID = browseID
        self.artworkURL = artworkURL
        self.biography = biography
        self.refreshedAt = refreshedAt
        self.unavailable = unavailable
    }
}

enum CatalogCacheState: Sendable, Equatable {
    case fresh
    case stale
    case unavailable

    static func resolve(refreshedAt: Date, unavailable: Bool,
                        now: Date = .init(), staleAfter: TimeInterval = 7 * 24 * 60 * 60) -> Self {
        if unavailable { return .unavailable }
        return now.timeIntervalSince(refreshedAt) > staleAfter ? .stale : .fresh
    }
}

struct CatalogReleaseProjection: Identifiable, Sendable, Equatable {
    var id: String { stableID }
    let stableID: String
    let title: String
    let artistName: String
    let artistStableID: String?
    let artworkURL: String?
    let year: Int?
    let kind: CatalogReleaseKind
    let cacheState: CatalogCacheState
    let tracks: [TrackSnapshot]
}

struct CatalogArtistProjection: Identifiable, Sendable, Equatable {
    var id: String { stableID }
    let stableID: String
    let name: String
    let artworkURL: String?
    let biography: String?
    let cacheState: CatalogCacheState
    let releases: [CatalogReleaseProjection]
    let tracks: [TrackSnapshot]
}
