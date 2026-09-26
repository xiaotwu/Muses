import Foundation
import SwiftData

/// A local follow of one stable YouTube Music podcast browse identity.
/// Following a show is deliberately local and never mutates YouTube account
/// subscriptions.
@Model
final class PodcastShow {
    @Attribute(.unique) var catalogID: String
    var title: String
    var artworkURL: String?
    var followedAt: Date
    var updatedAt: Date

    init(catalogID: String, title: String, artworkURL: String? = nil,
         followedAt: Date = .init(), updatedAt: Date = .init()) {
        self.catalogID = catalogID
        self.title = title
        self.artworkURL = artworkURL
        self.followedAt = followedAt
        self.updatedAt = updatedAt
    }
}

/// Durable user state for one stable YouTube video episode. Display metadata
/// may refresh, while progress and played state remain local user truth.
@Model
final class PodcastEpisodeState {
    @Attribute(.unique) var videoID: String
    var showCatalogID: String
    var title: String
    var artworkURL: String?
    var publishedAt: Date?
    var durationMs: Int?
    var lastPositionMs: Double
    var completed: Bool
    var playedAt: Date?
    var availabilityRaw: String
    var updatedAt: Date

    init(videoID: String, showCatalogID: String, title: String,
         artworkURL: String? = nil, publishedAt: Date? = nil,
         durationMs: Int? = nil, lastPositionMs: Double = 0,
         completed: Bool = false, playedAt: Date? = nil,
         availability: TrackAvailability = .available,
         updatedAt: Date = .init()) {
        self.videoID = videoID
        self.showCatalogID = showCatalogID
        self.title = title
        self.artworkURL = artworkURL
        self.publishedAt = publishedAt
        self.durationMs = durationMs
        self.lastPositionMs = lastPositionMs
        self.completed = completed
        self.playedAt = playedAt
        self.availabilityRaw = availability.rawValue
        self.updatedAt = updatedAt
    }

    var availability: TrackAvailability {
        get { TrackAvailability(rawValue: availabilityRaw) ?? .unavailable }
        set { availabilityRaw = newValue.rawValue }
    }
}

/// A video can occur in multiple shows. Progress belongs to the video, while
/// membership belongs to each source-backed show/video pair.
@Model
final class PodcastEpisodeMembership {
    @Attribute(.unique) var key: String
    var showCatalogID: String
    var videoID: String

    init(showCatalogID: String, videoID: String) {
        self.key = showCatalogID + "|" + videoID
        self.showCatalogID = showCatalogID
        self.videoID = videoID
    }
}
