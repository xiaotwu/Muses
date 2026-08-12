import Foundation

/// LRCLIB 歌词 API 的 URL 构造器。
///
/// 所有方法返回已百分号编码的 `URL`,可直接交给 `URLSession` 使用。
/// 纯函数,无 I/O,可独立单元测试。
enum LyricsEndpoint {
    /// LRCLIB 精确匹配接口。返回单条歌词(含 plainLyrics / syncedLyrics)。
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

    /// LRCLIB 模糊搜索接口。返回候选数组,当 `/api/get` 未命中时回退使用。
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

    /// Musixmatch 公共 Web API key(嵌于其官网 JS,非个人凭据)。
    /// 个人使用;失败时 `LyricsService` 自动回退 LRCLIB。
    static let musixmatchApiKey = "1603acfb09e00fa3f6c4e8c4d30f40c8"

    /// Musixmatch `track.search`:按曲名/艺人搜索,优先返回带同步歌词的曲目。
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

    /// Musixmatch `track.subtitle.get`:返回同步歌词(LRC `subtitle_body`)。
    static func musixmatchSubtitle(trackId: Int) -> URL {
        var components = URLComponents(string: "https://api.musixmatch.com/ws/1.1/track.subtitle.get")!
        components.queryItems = [
            URLQueryItem(name: "track_id", value: String(trackId)),
            URLQueryItem(name: "apikey", value: musixmatchApiKey),
        ]
        return components.url!
    }

    /// Musixmatch `track.lyrics.get`:返回纯文本歌词(`lyrics_body`)。
    static func musixmatchLyrics(trackId: Int) -> URL {
        var components = URLComponents(string: "https://api.musixmatch.com/ws/1.1/track.lyrics.get")!
        components.queryItems = [
            URLQueryItem(name: "track_id", value: String(trackId)),
            URLQueryItem(name: "apikey", value: musixmatchApiKey),
        ]
        return components.url!
    }
}