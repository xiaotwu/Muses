import Foundation

/// User-owned policy for choosing where Home candidates come from.
/// The persisted raw value is intentionally stable because it also identifies
/// an isolated cache tree.
enum HomeRecommendationMode: String, Codable, CaseIterable, Sendable {
    case muses
    case youtubeMusic

    var cacheNamespace: String {
        switch self {
        case .muses: "muses-v1"
        case .youtubeMusic: "youtube-music-v1"
        }
    }

    var label: String {
        switch self {
        case .muses: "Muses"
        case .youtubeMusic: "YouTube Music"
        }
    }
}
