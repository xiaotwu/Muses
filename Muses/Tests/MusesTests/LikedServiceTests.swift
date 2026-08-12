import Testing
import Foundation
import SwiftData
@testable import Muses

/// 收藏功能测试:toggleLike 翻转 + 持久化,likedTracks 过滤。
@MainActor
@Suite("LikedService")
struct LikedServiceTests {

    private func makeContainer() throws -> ModelContainer {
        try makeModelContainer(inMemory: true)
    }

    private func makeTrack(in container: ModelContainer, title: String = "Test") -> Track {
        let ctx = ModelContext(container)
        let track = Track(source: .local, title: title, artist: "Artist", durationMs: 200000)
        ctx.insert(track)
        try? ctx.save()
        return track
    }

    private func makeLibrary(container: ModelContainer) -> LibraryService {
        LibraryService(modelContainer: container, metadata: MetadataService(artworkCache: .default))
    }

    @Test("toggleLike 翻转 liked 并持久化")
    func toggleLikeFlipsAndPersists() throws {
        let container = try makeContainer()
        let library = makeLibrary(container: container)
        let track = makeTrack(in: container, title: "Song A")

        #expect(!track.liked)
        #expect(library.likedRevision == 0)

        library.toggleLike(track)

        #expect(library.likedRevision == 1)
        // Re-fetch in a fresh context to verify persistence.
        let ctx = ModelContext(container)
        let id = track.id
        let fetched = try ctx.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.id == id })).first
        #expect(fetched?.liked == true)

        // Toggle back off.
        library.toggleLike(track)
        #expect(library.likedRevision == 2)
        let ctx2 = ModelContext(container)
        let fetched2 = try ctx2.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.id == id })).first
        #expect(fetched2?.liked == false)
    }

    @Test("likedTracks 只返回 liked=true")
    func likedTracksFilters() throws {
        let container = try makeContainer()
        let library = makeLibrary(container: container)

        let t1 = makeTrack(in: container, title: "Liked Song")
        let _ = makeTrack(in: container, title: "Unliked Song")

        library.toggleLike(t1)

        let liked = library.likedTracks()
        #expect(liked.count == 1)
        #expect(liked.first?.title == "Liked Song")
    }
}