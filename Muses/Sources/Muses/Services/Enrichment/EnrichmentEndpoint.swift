import Foundation

/// URL builders for the online metadata enrichment providers.
///
/// All methods return fully-formed, percent-encoded `URL`s ready to be passed
/// to `URLSession`. They are pure functions — no I/O — so they can be unit
/// tested without networking.
enum EnrichmentEndpoint {
    /// iTunes Search API. Free, no token required.
    /// Example: `https://itunes.apple.com/search?term=Daft+Punk+One+More+Time&entity=song&limit=5`
    static func itunesSearch(term: String) -> URL {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        // `+` is a valid query character but URLComponents will percent-encode
        // spaces as `%20` by default; iTunes accepts both.
        return components.url!
    }

    /// MusicBrainz release-group search. Requires a descriptive `User-Agent`
    /// header and a maximum of 1 request per second.
    /// Example: `https://musicbrainz.org/ws/2/release-group/?query=One+More+Time&fmt=json`
    static func musicBrainzReleaseGroup(query: String) -> URL {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release-group/")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        return components.url!
    }

    /// Cover Art Archive front-cover image for a MusicBrainz release ID.
    /// The endpoint responds with a redirect (302) to the actual image URL;
    /// `URLSession` follows redirects by default.
    /// Example: `https://coverartarchive.org/release/<mbid>/front`
    static func coverArt(releaseId: String) -> URL {
        URL(string: "https://coverartarchive.org/release/\(releaseId)/front")!
    }

    /// Upgrade a 100x100 iTunes artwork URL to 600x600 by replacing the
    /// size token. Falls back to the original URL if the token is absent.
    static func upgradeItunesArtwork(_ url: String) -> String {
        if url.contains("100x100bb") {
            return url.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        }
        return url
    }
}