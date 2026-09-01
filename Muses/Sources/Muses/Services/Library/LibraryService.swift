import Foundation
import Observation
import SwiftData

/// YouTube-native library operations. Every persisted Track has a stable
/// YouTube video identity; filesystem discovery and local-file repair are not
/// part of this service.
@MainActor
@Observable
final class LibraryService {
    let modelContainer: ModelContainer
    private(set) var likedRevision = 0
    private(set) var playRevision = 0
    private(set) var metadataRevision = 0

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func allTracks(search: String? = nil) -> [Track] {
        let context = ModelContext(modelContainer)
        let query = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else {
            return (try? context.fetch(FetchDescriptor<Track>(
                sortBy: [SortDescriptor(\.title)]))) ?? []
        }
        let descriptor = FetchDescriptor<Track>(
            predicate: #Predicate {
                $0.title.localizedStandardContains(query)
                    || $0.artist.localizedStandardContains(query)
                    || $0.albumTitle?.localizedStandardContains(query) == true
            },
            sortBy: [SortDescriptor(\.title)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func toggleLike(_ track: Track) {
        toggleLike(id: track.id)
    }

    func toggleLike(id: UUID) {
        let context = ModelContext(modelContainer)
        guard let track = try? context.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.id == id })).first else { return }
        track.liked.toggle()
        do {
            try context.save()
            likedRevision &+= 1
        } catch {
            AppLog.for("LibraryService").warning(
                "toggleLike save failed: \(error.localizedDescription)")
        }
    }

    func updateTrack(id: UUID, title: String, artist: String,
                     albumTitle: String?, albumArtist: String?,
                     trackNo: Int?, discNo: Int?, year: Int?,
                     genre: String?, lyrics: String?) {
        let context = ModelContext(modelContainer)
        guard let track = try? context.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.id == id })).first else { return }
        track.title = title
        track.artist = artist
        track.albumTitle = albumTitle
        track.albumArtist = albumArtist
        track.trackNo = trackNo
        track.discNo = discNo
        track.year = year
        track.genre = genre
        track.lyrics = lyrics
        do {
            try context.save()
            metadataRevision &+= 1
        } catch {
            AppLog.for("LibraryService").warning(
                "updateTrack save failed: \(error.localizedDescription)")
        }
    }

    func isLiked(id: UUID) -> Bool {
        let context = ModelContext(modelContainer)
        return ((try? context.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.id == id })).first)?.liked) ?? false
    }

    func track(by id: UUID) -> Track? {
        let context = ModelContext(modelContainer)
        return try? context.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.id == id })).first
    }

    func likedIDs(for ids: [UUID]) -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        let context = ModelContext(modelContainer)
        let rows = (try? context.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { ids.contains($0.id) && $0.liked == true }))) ?? []
        return Set(rows.map(\.id))
    }

    func likedTracks() -> [Track] {
        let context = ModelContext(modelContainer)
        return (try? context.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.liked == true },
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)]))) ?? []
    }

    func recordPlay(trackId: UUID) {
        let context = ModelContext(modelContainer)
        guard let track = try? context.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.id == trackId })).first else {
            AppLog.for("LibraryService").warning(
                "recordPlay missing track \(trackId)")
            return
        }
        track.lastPlayedAt = .init()
        track.playCount += 1
        do {
            try context.save()
            playRevision &+= 1
        } catch {
            AppLog.for("LibraryService").warning(
                "recordPlay save failed: \(error.localizedDescription)")
        }
    }

    func recentlyPlayedTracks(limit: Int = 20) -> [TrackSnapshot] {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Track>(
            predicate: #Predicate { $0.lastPlayedAt != nil },
            sortBy: [SortDescriptor(\.lastPlayedAt, order: .reverse)])
        guard let tracks = try? context.fetch(descriptor) else { return [] }
        var seen = Set<String>()
        var result: [TrackSnapshot] = []
        for track in tracks where seen.insert(track.youTubeId).inserted {
            result.append(TrackSnapshot(from: track))
            if result.count >= limit { break }
        }
        return result
    }

    func topArtistName() -> String? {
        let context = ModelContext(modelContainer)
        guard let tracks = try? context.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.playCount > 0 })) else { return nil }
        var totals: [String: Int] = [:]
        for track in tracks {
            totals[track.albumArtist ?? track.artist, default: 0] += track.playCount
        }
        return totals.max { $0.value < $1.value }?.key
    }

    struct DiscoverySignals: Sendable {
        let topArtistNames: [String]
        let recentlyPlayedArtistNames: [String]
        let likedArtistNames: [String]
    }

    func discoverySignalsAsync(limit: Int = 5) async -> DiscoverySignals {
        await Task.detached(priority: .utility) { [modelContainer] in
            let context = ModelContext(modelContainer)
            let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
            var topCounts: [String: Int] = [:]
            for track in tracks where track.playCount > 0 {
                topCounts[track.artist, default: 0] += track.playCount
            }
            let top = topCounts.sorted { $0.value > $1.value }
                .prefix(limit).map(\.key)
            let recent = Self.uniqueNames(
                tracks.compactMap { track in
                    track.lastPlayedAt.map { (track.artist, $0) }
                }.sorted { $0.1 > $1.1 }.map(\.0), limit: limit)
            let liked = Self.uniqueNames(
                tracks.filter(\.liked).sorted { $0.addedAt > $1.addedAt }.map(\.artist),
                limit: limit)
            return DiscoverySignals(
                topArtistNames: top,
                recentlyPlayedArtistNames: recent,
                likedArtistNames: liked)
        }.value
    }

    private nonisolated static func uniqueNames(_ names: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names {
            guard seen.insert(name.lowercased()).inserted else { continue }
            result.append(name)
            if result.count >= limit { break }
        }
        return result
    }
}
