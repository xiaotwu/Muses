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
}