import Foundation
import SwiftData

/// Enriches `Track`s that lack artwork or album metadata by querying the
/// iTunes Search API first (free, no token, generous rate limits) and falling
/// back to MusicBrainz + Cover Art Archive when iTunes has no match.
///
/// The service is `@MainActor` because `Track` is a SwiftData `@Model` (a
/// reference type bound to a `ModelContext`) and all reads/writes must happen
/// on a single actor. Network I/O is performed via `URLSession` whose delegate
/// queue can be off-main; the awaited data is hauled back to the main actor
/// before it touches a `Track`.
@MainActor
final class MetadataEnricherService {
    let session: URLSession
    let artworkCache: ArtworkCache
    let modelContainer: ModelContainer

    /// Tracks the last MusicBrainz request timestamp to enforce the
    /// documented 1 request/second rate limit.
    private var lastMBRequest: Date = .distantPast

    private let log = AppLog.for("MetadataEnricherService")

    init(session: URLSession = .shared,
         artworkCache: ArtworkCache = .default,
         modelContainer: ModelContainer) {
        self.session = session
        self.artworkCache = artworkCache
        self.modelContainer = modelContainer
    }

    /// Enrich a single track by its ID. Fetches the track from a fresh
    /// `ModelContext`, sets `.enriching`, queries the network, and persists
    /// the result. Safe to call from the main actor.
    ///
    /// - Parameter trackId: The persistent identifier of the `Track` to enrich.
    /// - Returns: `true` if the track was found and enriched successfully,
    ///   `false` if no match was found or the track could not be loaded.
    @discardableResult
    func enrich(trackId: UUID) async -> Bool {
        let ctx = ModelContext(modelContainer)
        guard let track = try? ctx.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.id == trackId })).first else {
            log.warning("enrich: track \(trackId) not found")
            return false
        }

        track.metadataStatusRaw = MetadataStatus.enriching.rawValue
        try? ctx.save()

        // iTunes first — fast and no rate limit.
        if await enrichWithItunes(track, context: ctx) {
            track.metadataStatusRaw = MetadataStatus.complete.rawValue
            try? ctx.save()
            return true
        }

        // MusicBrainz fallback — rate limited to 1 req/sec.
        if await enrichWithMusicBrainz(track, context: ctx) {
            track.metadataStatusRaw = MetadataStatus.complete.rawValue
            try? ctx.save()
            return true
        }

        track.metadataStatusRaw = MetadataStatus.missing.rawValue
        try? ctx.save()
        return false
    }

    /// Enrich an `Artist` entity by its ID: queries iTunes for a representative
    /// track (gives us `artistId`/`primaryGenreName`/`artworkUrl100`), downloads
    /// the artwork, and persists. Falls back to MusicBrainz for MBID + genre.
    @discardableResult
    func enrichArtist(artistId: UUID) async -> Bool {
        let ctx = ModelContext(modelContainer)
        guard let artist = try? ctx.fetch(FetchDescriptor<Artist>(
            predicate: #Predicate { $0.id == artistId })).first else {
            log.warning("enrichArtist: artist \(artistId) not found")
            return false
        }

        // iTunes first — fast, no rate limit.
        if await enrichArtistWithItunes(artist, context: ctx) {
            try? ctx.save()
            return true
        }

        return false
    }

    // MARK: - Artist iTunes

    private func enrichArtistWithItunes(_ artist: Artist, context ctx: ModelContext) async -> Bool {
        let url = EnrichmentEndpoint.itunesArtistSearch(term: artist.name)

        guard let data = await get(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first else {
            return false
        }

        if let artistId = first["artistId"] as? Int {
            artist.itunesArtistId = artistId
        }
        if let genre = first["primaryGenreName"] as? String, !genre.isEmpty {
            artist.primaryGenre = genre
        }
        if let artwork100 = first["artworkUrl100"] as? String {
            let upgraded = EnrichmentEndpoint.upgradeItunesArtwork(artwork100)
            artist.artworkUrl = upgraded
            if let artworkURL = URL(string: upgraded),
               let imageData = await get(artworkURL) {
                if let hash = try? artworkCache.store(imageData) {
                    artist.artworkHash = hash
                }
            }
        }

        return true
    }

    // MARK: - iTunes

    private func enrichWithItunes(_ track: Track, context ctx: ModelContext) async -> Bool {
        let term = "\(track.title) \(track.artist)"
        let url = EnrichmentEndpoint.itunesSearch(term: term)

        guard let data = await get(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first else {
            return false
        }

        // Artwork: upgrade 100x100 -> 600x600, download, store locally.
        if let artwork100 = first["artworkUrl100"] as? String {
            let upgraded = EnrichmentEndpoint.upgradeItunesArtwork(artwork100)
            track.artworkUrl = upgraded
            if let artworkURL = URL(string: upgraded),
               let imageData = await get(artworkURL) {
                if let hash = try? artworkCache.store(imageData) {
                    track.localArtworkHash = hash
                }
            }
        }

        if let collection = first["collectionName"] as? String, !collection.isEmpty {
            track.albumTitle = collection
        }

        if let releaseDate = first["releaseDate"] as? String {
            track.year = parseYear(from: releaseDate) ?? track.year
        }

        return true
    }

    // MARK: - MusicBrainz

    private func enrichWithMusicBrainz(_ track: Track, context ctx: ModelContext) async -> Bool {
        let query = "\(track.title) AND artist:\(track.artist)"
        let url = EnrichmentEndpoint.musicBrainzReleaseGroup(query: query)

        // Enforce 1 req/sec rate limit.
        await waitForMusicBrainzRateLimit()

        var request = URLRequest(url: url)
        // MusicBrainz requires a descriptive User-Agent; requests without one
        // may be throttled or rejected.
        request.setValue("Muses/1.0 (https://github.com/muses)", forHTTPHeaderField: "User-Agent")

        guard let data = await data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let releaseGroups = json["release-groups"] as? [[String: Any]],
              let first = releaseGroups.first,
              let mbid = first["id"] as? String else {
            return false
        }

        // Album title + year from the release group.
        if let title = first["title"] as? String, !title.isEmpty {
            track.albumTitle = title
        }
        if let firstRelease = first["first-release-date"] as? String {
            track.year = parseYear(from: firstRelease) ?? track.year
        }

        // Artwork via Cover Art Archive.
        let coverURL = EnrichmentEndpoint.coverArt(releaseId: mbid)
        if let imageData = await get(coverURL) {
            track.artworkUrl = coverURL.absoluteString
            if let hash = try? artworkCache.store(imageData) {
                track.localArtworkHash = hash
            }
        }

        return true
    }

    /// Sleeps (off the main actor) until at least 1 second has elapsed since
    /// the last MusicBrainz request, then records the new request time.
    private func waitForMusicBrainzRateLimit() async {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastMBRequest)
        if elapsed < 1.0 {
            let remaining = 1.0 - elapsed
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        lastMBRequest = Date()
    }

    // MARK: - Helpers

    /// GET a URL and return its body data, logging and swallowing transport
    /// errors so a single failed endpoint doesn't abort the whole enrichment.
    private func get(_ url: URL) async -> Data? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                log.warning("GET \(url) failed with non-2xx")
                return nil
            }
            return data
        } catch {
            log.error("GET \(url) transport error: \(error)")
            return nil
        }
    }

    /// Fetch using a custom URLRequest (used to attach MusicBrainz User-Agent).
    private func data(for request: URLRequest) async -> Data? {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                log.warning("\(request.url?.absoluteString ?? "?") non-2xx")
                return nil
            }
            return data
        } catch {
            log.error("transport error: \(error)")
            return nil
        }
    }

    /// Parse a 4-digit year from an ISO-8601-ish date string
    /// (e.g. `"2001-03-07T08:00:00Z"` or `"2001-03-07"` or `"2001"`).
    private func parseYear(from dateString: String) -> Int? {
        let prefix = dateString.prefix(4)
        return Int(prefix)
    }
}