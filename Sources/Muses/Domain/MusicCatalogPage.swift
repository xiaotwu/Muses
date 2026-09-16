import Foundation

/// Public source metadata only. Display names never determine identity or type.
enum MusicCatalogKind: String, CaseIterable, Sendable, Codable {
    case song, video, album, artist, playlist, podcast, episode
}

struct MusicCatalogLink: Equatable, Sendable, Codable {
    let id: String
    let title: String
    let kind: MusicCatalogKind
}

struct MusicCatalogChannel: Equatable, Sendable, Codable {
    let id: String
    let title: String
}

struct MusicCatalogItem: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let kind: MusicCatalogKind
    let title: String
    let subtitle: String
    let artwork: URL?
    let artists: [MusicCatalogLink]
    let releases: [MusicCatalogLink]
    // A channel endpoint without an artist page type is not an artist credit.
    let channels: [MusicCatalogChannel]
}

/// Opaque, volatile continuation. Deliberately not Codable; never log its contents.
struct MusicCatalogCursor: Sendable {
    let session: UUID
    let endpoint: String
    let token: String
}

struct MusicCatalogFilter: Sendable {
    let kind: MusicCatalogKind
    let params: String
}

struct MusicCatalogPage: Sendable {
    let items: [MusicCatalogItem]
    let filters: [MusicCatalogFilter]
    let next: MusicCatalogCursor?
    let fetchedAt: Date
    let region: String
    var relatedItems: [MusicCatalogItem] = []
    var isStale = false
    var refreshFailed = false
    let source = URL(string: "https://music.youtube.com")!
}

protocol MusicCatalogProviding: Sendable {
    func search(_ query: String, kind: MusicCatalogKind?) async throws -> MusicCatalogPage
    func browse(_ id: String) async throws -> MusicCatalogPage
    func next(_ cursor: MusicCatalogCursor) async throws -> MusicCatalogPage
    func reset() async
}

enum MusicCatalogError: Error {
    case unavailable, invalidResponse, unsupportedCategory, invalidIdentity, expiredCursor, responseTooLarge
}
