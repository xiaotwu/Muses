import Foundation
import Observation
import SwiftData

struct PodcastEpisodeSnapshot: Equatable, Sendable {
    let videoID: String
    let showCatalogID: String
    let title: String
    let artworkURL: String?
    let publishedAt: Date?
    let durationMs: Int?
    let lastPositionMs: Double
    let completed: Bool
    let availability: TrackAvailability
}

struct PodcastShowSnapshot: Equatable, Sendable, Identifiable {
    var id: String { catalogID }
    let catalogID: String
    let title: String
    let artworkURL: String?
    let followedAt: Date
}

enum PodcastUnplayedOrder: Equatable, Sendable {
    case publicationDate
    case sourceOrder
}

struct PodcastUnplayedQueue: Equatable, Sendable {
    let videoIDs: [String]
    let order: PodcastUnplayedOrder
}

enum PodcastLibraryError: Error, Equatable {
    case invalidShowIdentity
    case invalidEpisodeIdentity
    case missingPublicationDate
}

/// Local podcast truth. Catalog pages remain rebuildable network data; follows,
/// progress and played state are persisted independently and never write to the
/// connected YouTube account.
@Observable
@MainActor
final class PodcastLibraryService {
    static let completionFraction = 0.90
    static let completionRemainingMs = 60_000

    private let modelContainer: ModelContainer
    private let saveContext: (ModelContext) throws -> Void
    private(set) var revision = 0
    private(set) var persistenceFailed = false
    private enum PendingProgressWrite {
        case position(videoID: String, positionMs: Double, durationMs: Int?)
        case completed(videoID: String)

        var videoID: String {
            switch self {
            case .position(let videoID, _, _), .completed(let videoID): videoID
            }
        }
    }
    private var pendingProgressWrites: [String: PendingProgressWrite] = [:]
    private var eventSubscription: UUID?
    private var activeEpisode: TrackSnapshot?

    init(modelContainer: ModelContainer, eventBus: PlaybackEventBus? = nil,
         saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.modelContainer = modelContainer
        self.saveContext = saveContext
        eventSubscription = eventBus?.subscribe { [weak self] event in
            self?.handle(event)
        }
    }

    func follow(_ show: MusicCatalogItem, now: Date = .init()) throws {
        guard show.kind == .podcast, Self.isStableShowID(show.id) else {
            throw PodcastLibraryError.invalidShowIdentity
        }
        let ctx = ModelContext(modelContainer)
        if let existing = try ctx.fetch(FetchDescriptor<PodcastShow>(
            predicate: #Predicate { $0.catalogID == show.id })).first {
            existing.title = show.title
            existing.artworkURL = show.artwork?.absoluteString
            existing.updatedAt = now
        } else {
            ctx.insert(PodcastShow(catalogID: show.id, title: show.title,
                                   artworkURL: show.artwork?.absoluteString,
                                   followedAt: now, updatedAt: now))
        }
        try saveContext(ctx)
        revision &+= 1
    }

    func unfollow(catalogID: String) throws {
        let ctx = ModelContext(modelContainer)
        for show in try ctx.fetch(FetchDescriptor<PodcastShow>(
            predicate: #Predicate { $0.catalogID == catalogID })) {
            ctx.delete(show)
        }
        try saveContext(ctx)
        revision &+= 1
    }

    func isFollowing(catalogID: String) -> Bool {
        let ctx = ModelContext(modelContainer)
        return ((try? ctx.fetch(FetchDescriptor<PodcastShow>(
            predicate: #Predicate { $0.catalogID == catalogID }))) ?? []).isEmpty == false
    }

    func followedShows() -> [PodcastShowSnapshot] {
        let ctx = ModelContext(modelContainer)
        let rows = (try? ctx.fetch(FetchDescriptor<PodcastShow>())) ?? []
        return rows.map { .init(catalogID: $0.catalogID, title: $0.title,
                                artworkURL: $0.artworkURL, followedAt: $0.followedAt) }
            .sorted { $0.followedAt == $1.followedAt
                ? $0.catalogID < $1.catalogID : $0.followedAt > $1.followedAt }
    }

    /// Refreshes rebuildable episode metadata without changing progress or
    /// completion. The service refuses non-episode and non-video identities.
    func ingest(show: MusicCatalogItem, episodes: [MusicCatalogItem],
                now: Date = .init()) throws {
        guard show.kind == .podcast, Self.isStableShowID(show.id) else {
            throw PodcastLibraryError.invalidShowIdentity
        }
        guard episodes.allSatisfy({ $0.kind == .episode && Self.videoID($0.id) != nil }) else {
            throw PodcastLibraryError.invalidEpisodeIdentity
        }
        let ctx = ModelContext(modelContainer)
        for episode in episodes {
            let videoID = Self.videoID(episode.id)!
            let membershipKey = show.id + "|" + videoID
            if try ctx.fetch(FetchDescriptor<PodcastEpisodeMembership>(
                predicate: #Predicate { $0.key == membershipKey })).isEmpty {
                ctx.insert(PodcastEpisodeMembership(showCatalogID: show.id, videoID: videoID))
            }
            if let existing = try ctx.fetch(FetchDescriptor<PodcastEpisodeState>(
                predicate: #Predicate { $0.videoID == videoID })).first {
                existing.title = episode.title
                existing.artworkURL = episode.artwork?.absoluteString
                existing.updatedAt = now
            } else {
                ctx.insert(PodcastEpisodeState(
                    videoID: videoID, showCatalogID: show.id,
                    title: episode.title,
                    artworkURL: episode.artwork?.absoluteString,
                    updatedAt: now))
            }
        }
        try saveContext(ctx)
        revision &+= 1
    }

    func enrich(_ metadata: [YouTubeVideoMetadata], now: Date = .init()) throws {
        guard !metadata.isEmpty else { return }
        let ctx = ModelContext(modelContainer)
        for item in metadata {
            let videoID = item.videoID
            guard Self.isVideoID(videoID),
                  let row = try ctx.fetch(FetchDescriptor<PodcastEpisodeState>(
                    predicate: #Predicate { $0.videoID == videoID })).first else { continue }
            if let publishedAt = item.publishedAt { row.publishedAt = publishedAt }
            if let durationMs = item.durationMs, durationMs > 0 {
                row.durationMs = durationMs
            }
            if let availability = item.availability { row.availability = availability }
            row.updatedAt = now
        }
        try saveContext(ctx)
        revision &+= 1
    }

    func updateProgress(videoID: String, positionMs: Double,
                        durationMs: Int?, now: Date = .init()) throws {
        guard Self.isVideoID(videoID), positionMs.isFinite, positionMs >= 0 else {
            throw PodcastLibraryError.invalidEpisodeIdentity
        }
        let ctx = ModelContext(modelContainer)
        guard let episode = try ctx.fetch(FetchDescriptor<PodcastEpisodeState>(
            predicate: #Predicate { $0.videoID == videoID })).first else {
            throw PodcastLibraryError.invalidEpisodeIdentity
        }
        let boundedDuration = durationMs.flatMap { $0 > 0 ? $0 : nil }
        episode.durationMs = boundedDuration ?? episode.durationMs
        let effectiveDuration = episode.durationMs
        episode.lastPositionMs = effectiveDuration.map {
            min(positionMs, Double($0))
        } ?? positionMs
        if let effectiveDuration,
           Self.isComplete(positionMs: episode.lastPositionMs,
                           durationMs: effectiveDuration) {
            episode.completed = true
            episode.playedAt = now
            episode.lastPositionMs = Double(effectiveDuration)
        }
        episode.updatedAt = now
        try saveContext(ctx)
        revision &+= 1
    }

    func markUnplayed(videoID: String, now: Date = .init()) throws {
        let ctx = ModelContext(modelContainer)
        guard let episode = try ctx.fetch(FetchDescriptor<PodcastEpisodeState>(
            predicate: #Predicate { $0.videoID == videoID })).first else {
            throw PodcastLibraryError.invalidEpisodeIdentity
        }
        episode.completed = false
        episode.playedAt = nil
        episode.lastPositionMs = 0
        episode.updatedAt = now
        try saveContext(ctx)
        revision &+= 1
    }

    func episodes(showCatalogID: String) -> [PodcastEpisodeSnapshot] {
        let ctx = ModelContext(modelContainer)
        let memberships = (try? ctx.fetch(FetchDescriptor<PodcastEpisodeMembership>(
            predicate: #Predicate { $0.showCatalogID == showCatalogID }))) ?? []
        let memberIDs = Set(memberships.map(\.videoID))
        let rows = (try? ctx.fetch(FetchDescriptor<PodcastEpisodeState>())) ?? []
        return rows.filter { memberIDs.contains($0.videoID) || $0.showCatalogID == showCatalogID }
            .map { Self.snapshot($0, showCatalogID: showCatalogID) }
            .sorted(by: Self.displayOrder)
    }

    func episode(videoID: String) -> PodcastEpisodeSnapshot? {
        let ctx = ModelContext(modelContainer)
        return (try? ctx.fetch(FetchDescriptor<PodcastEpisodeState>(
            predicate: #Predicate { $0.videoID == videoID })).first).map { Self.snapshot($0) }
    }

    /// Called by the existing session checkpoint timer and lifecycle handlers.
    /// No additional position observer or high-frequency persistence loop.
    func checkpoint(track: TrackSnapshot, positionMs: Double, durationSeconds: Double) {
        guard track.mediaKind == .podcastEpisode else { return }
        let duration = durationSeconds.isFinite && durationSeconds > 0
            && durationSeconds < Double(Int.max / 1000)
            ? Int(durationSeconds * 1000) : Self.durationMs(track)
        saveProgress(.position(videoID: track.youTubeId, positionMs: positionMs,
                               durationMs: duration))
    }

    func retryPendingProgress() {
        for pending in Array(pendingProgressWrites.values) { saveProgress(pending) }
    }

    private func saveProgress(_ write: PendingProgressWrite) {
        do {
            switch write {
            case .position(let videoID, let positionMs, let durationMs):
                try updateProgress(videoID: videoID, positionMs: positionMs,
                                   durationMs: durationMs)
            case .completed(let videoID):
                try markPlayed(videoID: videoID)
            }
            pendingProgressWrites.removeValue(forKey: write.videoID)
        } catch {
            pendingProgressWrites[write.videoID] = write
            AppLog.for("PodcastLibraryService").error("Podcast progress save failed: \(error.localizedDescription)")
        }
        persistenceFailed = !pendingProgressWrites.isEmpty
    }

    func markPlayed(videoID: String, now: Date = .init()) throws {
        let ctx = ModelContext(modelContainer)
        guard let row = try ctx.fetch(FetchDescriptor<PodcastEpisodeState>(
            predicate: #Predicate { $0.videoID == videoID })).first else {
            throw PodcastLibraryError.invalidEpisodeIdentity
        }
        row.completed = true
        row.playedAt = now
        row.updatedAt = now
        try saveContext(ctx)
        revision &+= 1
    }

    /// Oldest-to-newest playback order. Rows without a source-backed
    /// publication date are excluded instead of guessing from titles/order.
    func unplayedByPublicationDate(showCatalogID: String) throws -> [PodcastEpisodeSnapshot] {
        let rows = episodes(showCatalogID: showCatalogID)
            .filter { !$0.completed && $0.availability == .available }
        guard rows.allSatisfy({ $0.publishedAt != nil }) else {
            throw PodcastLibraryError.missingPublicationDate
        }
        return rows.sorted {
            if $0.publishedAt != $1.publishedAt { return $0.publishedAt! < $1.publishedAt! }
            return $0.videoID < $1.videoID
        }
    }

    /// Uses verified dates only when every visible unplayed episode has one.
    /// Otherwise the source's episode order is retained and reported as such.
    func unplayedQueue(showCatalogID: String,
                       sourceVideoIDs: [String]) -> PodcastUnplayedQueue {
        let states = Dictionary(uniqueKeysWithValues:
            episodes(showCatalogID: showCatalogID).map { ($0.videoID, $0) })
        var seen = Set<String>()
        let rows = sourceVideoIDs.filter { seen.insert($0).inserted }
            .compactMap { states[$0] }
            .filter { !$0.completed && $0.availability == .available }
        guard rows.allSatisfy({ $0.publishedAt != nil }) else {
            return .init(videoIDs: rows.map(\.videoID), order: .sourceOrder)
        }
        return .init(videoIDs: rows.sorted {
            if $0.publishedAt != $1.publishedAt {
                return $0.publishedAt! < $1.publishedAt!
            }
            return $0.videoID < $1.videoID
        }.map(\.videoID), order: .publicationDate)
    }

    static func isComplete(positionMs: Double, durationMs: Int) -> Bool {
        guard positionMs.isFinite, positionMs >= 0, durationMs > 0 else { return false }
        let duration = Double(durationMs)
        let threshold = duration > 2 * Double(completionRemainingMs)
            ? min(duration * completionFraction, duration - Double(completionRemainingMs))
            : duration * completionFraction
        return positionMs >= threshold
    }

    private static func snapshot(_ row: PodcastEpisodeState,
                                 showCatalogID: String? = nil) -> PodcastEpisodeSnapshot {
        .init(videoID: row.videoID, showCatalogID: showCatalogID ?? row.showCatalogID,
              title: row.title, artworkURL: row.artworkURL,
              publishedAt: row.publishedAt, durationMs: row.durationMs,
              lastPositionMs: row.lastPositionMs, completed: row.completed,
              availability: row.availability)
    }

    private static func displayOrder(_ lhs: PodcastEpisodeSnapshot,
                                     _ rhs: PodcastEpisodeSnapshot) -> Bool {
        switch (lhs.publishedAt, rhs.publishedAt) {
        case let (l?, r?) where l != r: return l > r
        case (_?, nil): return true
        case (nil, _?): return false
        default: return lhs.videoID < rhs.videoID
        }
    }

    private static func isStableShowID(_ id: String) -> Bool {
        id.hasPrefix("browse:") && id.count > "browse:".count
    }

    private static func videoID(_ id: String) -> String? {
        guard id.hasPrefix("video:") else { return nil }
        let value = String(id.dropFirst("video:".count))
        return isVideoID(value) ? value : nil
    }

    private static func isVideoID(_ value: String) -> Bool {
        value.count == 11 && value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
        }
    }

    private func handle(_ event: PlaybackEvent) {
        switch event {
        case .trackStarted(let track):
            activeEpisode = track.mediaKind == .podcastEpisode ? track : nil
        case .trackSeeked(let trackID, let toMs):
            guard let activeEpisode, activeEpisode.id == trackID else { return }
            saveProgress(.position(videoID: activeEpisode.youTubeId, positionMs: toMs,
                                   durationMs: Self.durationMs(activeEpisode)))
        case .trackPaused(let track):
            guard track.mediaKind == .podcastEpisode else { return }
        case .trackCompleted(let track, _, _):
            guard track.mediaKind == .podcastEpisode else { return }
            saveProgress(.completed(videoID: track.youTubeId))
            activeEpisode = nil
        case .trackSkipped(let track, let listenedMs, let positionMs),
             .trackStopped(let track, let listenedMs, let positionMs):
            guard track.mediaKind == .podcastEpisode else { return }
            saveProgress(.position(videoID: track.youTubeId,
                                   positionMs: positionMs ?? listenedMs,
                                   durationMs: Self.durationMs(track)))
            activeEpisode = nil
        case .trackResumed, .queueChanged, .outputDeviceChanged:
            break
        }
    }

    private static func durationMs(_ track: TrackSnapshot) -> Int? {
        guard track.durationSeconds.isFinite, track.durationSeconds > 0,
              track.durationSeconds < Double(Int.max / 1000) else { return nil }
        return Int(track.durationSeconds * 1000)
    }
}
