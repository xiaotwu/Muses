import Testing
import Foundation
import SwiftData
@testable import Muses

/// YouTube search service tests.
@MainActor
@Suite("YouTubeSearch")
struct YouTubeSearchTests {

    @Test("search returns bridge results")
    func searchReturnsResults() async throws {
        let container = try makeModelContainer(inMemory: true)
        let bridge = MockImportBridge()
        bridge.searchResults = [
            YTDlpBridge.YTDlpPlaylistEntry(id: "s1", title: "Result A", uploader: "Chan A", duration: 180),
            YTDlpBridge.YTDlpPlaylistEntry(id: "s2", title: "Result B", uploader: "Chan B", duration: 240),
        ]
        let service = YouTubeSearchService(bridge: bridge, modelContainer: container)

        let results = try await service.search(query: "test query")
        #expect(results.count == 2)
        #expect(results[0].id == "s1")
        #expect(bridge.searchCallCount == 1)
    }

    @Test("search with empty query returns empty array without calling bridge")
    func searchEmptyQuerySkipsBridge() async throws {
        let container = try makeModelContainer(inMemory: true)
        let bridge = MockImportBridge()
        let service = YouTubeSearchService(bridge: bridge, modelContainer: container)

        let results = try await service.search(query: "   ")
        #expect(results.isEmpty)
        #expect(bridge.searchCallCount == 0)
    }

    @Test("importAsTrack creates .youtube Track and deduplicates")
    func importAsTrackCreatesAndDeduplicates() async throws {
        let container = try makeModelContainer(inMemory: true)
        let bridge = MockImportBridge()
        let service = YouTubeSearchService(bridge: bridge, modelContainer: container)

        let entry = YTDlpBridge.YTDlpPlaylistEntry(id: "duplicate01", title: "Dup Song", uploader: "Dup Artist", duration: 200)

        // First import → creates the Track
        let snap1 = try await service.importAsTrack(entry: entry)
        #expect(snap1.youTubeId == "duplicate01")
        #expect(snap1.title == "Dup Song")

        // Verify persistence
        let ctx = ModelContext(container)
        let tracks = try ctx.fetch(FetchDescriptor<Track>())
        #expect(tracks.count == 1)
        #expect(tracks.first?.youTubeId == "duplicate01")

        // Importing the same entry again → returns the existing track, no new one
        let snap2 = try await service.importAsTrack(entry: entry)
        #expect(snap2.id == snap1.id)
        let tracks2 = try ctx.fetch(FetchDescriptor<Track>())
        #expect(tracks2.count == 1, "Deduplication: duplicate track should not be created")
    }
    @Test("channel and malformed search entries cannot persist or enter a video queue")
    func rejectsNonVideoResults() async throws {
        let container = try makeModelContainer(inMemory: true)
        let service = YouTubeSearchService(bridge: MockImportBridge(), modelContainer: container)
        let channel = YTDlpBridge.YTDlpPlaylistEntry(id: "UCoUM-UJ7rirJYP8CQ0EIaHA", title: "Bruno Mars")
        let invalid = YTDlpBridge.YTDlpPlaylistEntry(id: "../../bad", title: "Invalid")
        #expect(channel.resourceKind == .channel)
        #expect(channel.resourceURL?.path == "/channel/UCoUM-UJ7rirJYP8CQ0EIaHA")
        for entry in [channel, invalid] {
            await #expect(throws: YouTubeImportError.invalidURL) {
                try await service.importAsTrack(entry: entry)
            }
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Track>()) == 0)
        let video = YTDlpBridge.YTDlpPlaylistEntry(id: "lY5V4hSLWY8", title: "Song")
        let snapshot = try await service.importAsTrack(entry: video)
        let queue = TrackSnapshot.playbackContext(playing: snapshot, youTubeEntries: [channel, video, invalid])
        #expect(queue.map(\.youTubeId) == [video.id])
        let data = try JSONEncoder().encode(channel)
        #expect(try JSONDecoder().decode(YTDlpBridge.YTDlpPlaylistEntry.self, from: data).resourceKind == .channel)
    }

}
