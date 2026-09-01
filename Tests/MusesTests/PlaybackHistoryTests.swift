import Foundation
import SwiftData
import Testing
@testable import Muses

@MainActor
@Suite("Playback History")
struct PlaybackHistoryTests {
    private func makeTrack(_ title: String, artist: String, videoID: String) -> Track {
        Track(title: title, artist: artist, durationMs: 1_000, youTubeId: videoID)
    }

    @Test("recording a play updates the persisted YouTube track")
    func recordPlayUpdatesHistory() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let track = makeTrack("Track", artist: "Artist", videoID: "video-a")
        context.insert(track)
        try context.save()

        let library = LibraryService(modelContainer: container)
        library.recordPlay(trackId: track.id)
        library.recordPlay(trackId: track.id)

        let fresh = ModelContext(container)
        let tracks = try fresh.fetch(FetchDescriptor<Track>())
        let saved = try #require(tracks.first { $0.id == track.id })
        #expect(saved.playCount == 2)
        #expect(saved.lastPlayedAt != nil)
        #expect(library.playRevision == 2)
    }

    @Test("recently played preserves recency and deduplicates video IDs")
    func recentTracksAreYouTubeOnlyAndDeduplicated() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let older = makeTrack("Older", artist: "A", videoID: "same")
        older.lastPlayedAt = Date().addingTimeInterval(-120)
        let newer = makeTrack("Newer", artist: "A", videoID: "same")
        newer.lastPlayedAt = Date()
        let distinct = makeTrack("Distinct", artist: "B", videoID: "other")
        distinct.lastPlayedAt = Date().addingTimeInterval(-10)
        context.insert(older); context.insert(newer); context.insert(distinct)
        try context.save()

        let recent = LibraryService(modelContainer: container).recentlyPlayedTracks(limit: 10)
        #expect(recent.map(\.title) == ["Newer", "Distinct"])
        #expect(recent.allSatisfy { !$0.youTubeId.isEmpty })
    }
}
