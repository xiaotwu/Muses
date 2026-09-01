import Foundation

/// YouTube Music world-catalog URLs for Home discovery (yt-dlp + cookies).
enum YouTubeMusicCatalog {
    static let charts = "https://music.youtube.com/charts"
    static let newReleases = "https://music.youtube.com/new_releases"
    static let moods = "https://music.youtube.com/moods"

    static func mix(videoId: String) -> String {
        "https://www.youtube.com/watch?v=\(videoId)&list=RD\(videoId)"
    }
}
