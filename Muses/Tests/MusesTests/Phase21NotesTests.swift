import Foundation
import SwiftData
import Testing
@testable import Muses

@MainActor
@Suite("Notes and Bookmarks")
struct Phase21NotesTests {
    private func makeContainer() throws -> ModelContainer {
        try makeModelContainer(inMemory: true)
    }

    private func seedTrack(_ container: ModelContainer, title: String = "Song") throws -> Track {
        let context = ModelContext(container)
        let track = Track(title: title, artist: "Artist", youTubeId: "video-\(UUID().uuidString)")
        context.insert(track)
        try context.save()
        return track
    }

    @Test("track notes upsert and delete when content becomes empty")
    func trackNoteUpsert() throws {
        let container = try makeContainer()
        let service = NotesService(modelContainer: container, enabledProvider: { true })
        let track = try seedTrack(container)

        service.setTrackNote(trackId: track.id, content: "first")
        service.setTrackNote(trackId: track.id, content: "revised")
        #expect(service.note(forTrack: track.id)?.content == "revised")

        service.setTrackNote(trackId: track.id, content: "  ")
        #expect(service.note(forTrack: track.id) == nil)
    }

    @Test("bookmarks keep stable track ownership and timestamp order")
    func bookmarksAreOrderedAndScoped() throws {
        let container = try makeContainer()
        let service = NotesService(modelContainer: container, enabledProvider: { true })
        let first = try seedTrack(container, title: "First")
        let second = try seedTrack(container, title: "Second")

        service.addBookmark(trackId: first.id, timestampMs: 30, title: "late", note: nil)
        service.addBookmark(trackId: first.id, timestampMs: 10, title: "early", note: nil)
        service.addBookmark(trackId: second.id, timestampMs: 5, title: "other", note: nil)

        #expect(service.bookmarks(forTrack: first.id).map(\.timestampMs) == [10, 30])
        #expect(service.bookmarks(forTrack: second.id).map(\.timestampMs) == [5])
    }

    @Test("disabled notes preserve existing user data")
    func disabledServiceDoesNotWrite() throws {
        let container = try makeContainer()
        let track = try seedTrack(container)
        let enabled = NotesService(modelContainer: container, enabledProvider: { true })
        enabled.setTrackNote(trackId: track.id, content: "saved")

        let disabled = NotesService(modelContainer: container, enabledProvider: { false })
        disabled.setTrackNote(trackId: track.id, content: "changed")
        disabled.addBookmark(trackId: track.id, timestampMs: 1, title: nil, note: nil)

        #expect(enabled.note(forTrack: track.id)?.content == "saved")
        #expect(enabled.bookmarks(forTrack: track.id).isEmpty)
    }
}
