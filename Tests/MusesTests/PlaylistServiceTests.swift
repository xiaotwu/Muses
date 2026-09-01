import Testing
import Foundation
import SwiftData
@testable import Muses

/// Playlist service CRUD + ordering tests.
@MainActor
@Suite("PlaylistService")
struct PlaylistServiceTests {

    private func makeContainer() throws -> ModelContainer {
        try makeModelContainer(inMemory: true)
    }

    private func makeTrack(in container: ModelContainer, title: String = "Test Track") -> Track {
        let ctx = ModelContext(container)
        let track = Track(title: title, artist: "Artist", durationMs: 200000, youTubeId: "test-video")
        ctx.insert(track)
        try? ctx.save()
        return track
    }

    @Test("create 创建空歌单")
    func createPlaylist() throws {
        let container = try makeContainer()
        let service = PlaylistService(modelContainer: container)

        let playlist = service.create(name: "My Playlist")
        #expect(playlist.name == "My Playlist")
        #expect(playlist.items == nil || playlist.items?.isEmpty == true)

        // Verify persistence
        let ctx = ModelContext(container)
        let playlists = try ctx.fetch(FetchDescriptor<Playlist>())
        #expect(playlists.count == 1)
        #expect(playlists.first?.name == "My Playlist")
    }

    @Test("addTrack 追加曲目 + 去重")
    func addTrackAndDedup() throws {
        let container = try makeContainer()
        let service = PlaylistService(modelContainer: container)
        let track = makeTrack(in: container, title: "Song A")

        let playlist = service.create(name: "P1")
        service.addTrack(playlist, track: track)

        // Verify there is 1 item
        let ctx = ModelContext(container)
        let p = try #require(try ctx.fetch(FetchDescriptor<Playlist>()).first)
        let items = (p.items ?? []).sorted { $0.order < $1.order }
        #expect(items.count == 1)
        #expect(items[0].order == 0)
        #expect(items[0].track?.title == "Song A")

        // Adding the same track again → deduped
        service.addTrack(playlist, track: track)
        let items2 = (p.items ?? [])
        #expect(items2.count == 1, "去重:不应添加重复 track")
    }

    @Test("moveItem 拖拽重排 order")
    func moveItemReorders() throws {
        let container = try makeContainer()
        let service = PlaylistService(modelContainer: container)
        let t1 = makeTrack(in: container, title: "A")
        let t2 = makeTrack(in: container, title: "B")
        let t3 = makeTrack(in: container, title: "C")

        let playlist = service.create(name: "P2")
        service.addTrack(playlist, track: t1)
        service.addTrack(playlist, track: t2)
        service.addTrack(playlist, track: t3)

        // Verify the initial order A B C
        let ctx = ModelContext(container)
        let p = try #require(try ctx.fetch(FetchDescriptor<Playlist>()).first)
        var items = (p.items ?? []).sorted { $0.order < $1.order }
        #expect(items.map { $0.track?.title } == ["A", "B", "C"])

        // Move C (index 2) to index 0
        service.moveItem(in: p, from: 2, to: 0)
        items = (p.items ?? []).sorted { $0.order < $1.order }
        #expect(items.map { $0.track?.title } == ["C", "A", "B"])
        #expect(items.map { $0.order } == [0, 1, 2])
    }

    @Test("delete 歌单级联删 items")
    func deleteCascadesItems() throws {
        let container = try makeContainer()
        let service = PlaylistService(modelContainer: container)
        let track = makeTrack(in: container, title: "Doomed Song")

        let playlist = service.create(name: "To Delete")
        service.addTrack(playlist, track: track)

        // Verify there is 1 item
        let ctx = ModelContext(container)
        #expect(try ctx.fetch(FetchDescriptor<PlaylistItem>()).count == 1)

        // Delete the playlist
        service.delete(playlist)

        // Playlist + items must disappear; the Track survives (nullify)
        #expect(try ctx.fetch(FetchDescriptor<Playlist>()).count == 0)
        #expect(try ctx.fetch(FetchDescriptor<PlaylistItem>()).count == 0)
        #expect(try ctx.fetch(FetchDescriptor<Track>()).count == 1, "Track 应保留(nullify)")
    }

    @Test("deleteWithUndoSnapshot restores order and pinned state")
    func deleteAndUndoRestoresPlaylist() throws {
        let container = try makeContainer()
        let service = PlaylistService(modelContainer: container)
        let a = makeTrack(in: container, title: "A")
        let b = makeTrack(in: container, title: "B")
        let playlist = service.create(name: "Recover me")
        service.addTrack(playlist, track: a)
        service.addTrack(playlist, track: b)
        service.togglePin(playlist)

        let snapshot = try #require(service.deleteWithUndoSnapshot(playlist))
        #expect(try ModelContext(container).fetch(FetchDescriptor<Playlist>()).isEmpty)
        let restored = try #require(service.restore(snapshot))
        #expect(restored.name == "Recover me")
        #expect(restored.pinned)
        #expect((restored.items ?? []).sorted { $0.order < $1.order }
            .compactMap { $0.track?.title } == ["A", "B"])
    }
}
