import Foundation

/// URL builder for the LRCLIB lyrics API.
///
/// Every method returns a percent-encoded `URL`, ready to hand to `URLSession`.
/// Pure functions with no I/O, unit-testable in isolation.
enum LyricsEndpoint {
    /// LRCLIB exact-match endpoint. Returns a single lyric (with plainLyrics / syncedLyrics).
    /// Example: `https://lrclib.net/api/get?track_name=One%20More%20Time&artist_name=Daft%20Punk`
    static func lrclib(track: String, artist: String, album: String?) -> URL {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "track_name", value: track),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if let album, !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        components.queryItems = items
        return components.url!
    }

    /// LRCLIB fuzzy-search endpoint. Returns a candidate array, used as a fallback when `/api/get` misses.
    /// Example: `https://lrclib.net/api/search?track_name=One%20More%20Time&artist_name=Daft%20Punk`
    static func lrclibSearch(track: String, artist: String) -> URL {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: track),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        return components.url!
    }

    // MARK: - Musixmatch

    /// Musixmatch public Web API key (embedded in their site's JS, not a personal credential).
    /// For personal use; `LyricsService` automatically falls back to LRCLIB on failure.
    static let musixmatchApiKey = "1603acfb09e00fa3f6c4e8c4d30f40c8"

    /// Musixmatch `track.search`: searches by track/artist, preferring tracks with synced lyrics.
    static func musixmatchSearch(track: String, artist: String) -> URL {
        var components = URLComponents(string: "https://api.musixmatch.com/ws/1.1/track.search")!
        components.queryItems = [
            URLQueryItem(name: "q_track", value: track),
            URLQueryItem(name: "q_artist", value: artist),
            URLQueryItem(name: "f_subtitle_has_length", value: "1"),
            URLQueryItem(name: "s_track_rating", value: "desc"),
            URLQueryItem(name: "page_size", value: "5"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "apikey", value: musixmatchApiKey),
        ]
        return components.url!
    }

    /// Musixmatch `track.subtitle.get`: returns synced lyrics (LRC `subtitle_body`).
    static func musixmatchSubtitle(trackId: Int) -> URL {
        var components = URLComponents(string: "https://api.musixmatch.com/ws/1.1/track.subtitle.get")!
        components.queryItems = [
            URLQueryItem(name: "track_id", value: String(trackId)),
            URLQueryItem(name: "apikey", value: musixmatchApiKey),
        ]
        return components.url!
    }

    /// Musixmatch `track.lyrics.get`: returns plain-text lyrics (`lyrics_body`).
    static func musixmatchLyrics(trackId: Int) -> URL {
        var components = URLComponents(string: "https://api.musixmatch.com/ws/1.1/track.lyrics.get")!
        components.queryItems = [
            URLQueryItem(name: "track_id", value: String(trackId)),
            URLQueryItem(name: "apikey", value: musixmatchApiKey),
        ]
        return components.url!
    }
}