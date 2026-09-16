import Foundation
import SwiftData
import Testing
@testable import Muses

@MainActor
@Suite("Notes and Bookmarks")
struct NotesFeatureTests {
    @Test("save failure rolls back notes and bookmarks and remains retryable")
    func saveFailureIsAtomic() throws {
        let container = try makeContainer()
        let track = try seedTrack(container)
        let working = NotesService(modelContainer: container, enabledProvider: { true })
        #expect(working.setTrackNote(trackId: track.id, content: "Original"))
        enum Failure: Error { case diskFull }
        let failing = NotesService(modelContainer: container, enabledProvider: { true },
                                   saveContext: { _ in throw Failure.diskFull })
        #expect(!failing.setTrackNote(trackId: track.id, content: "Unsaved draft"))
        #expect(failing.lastError != nil)
        #expect(failing.revision == 0)
        #expect(working.note(forTrack: track.id)?.content == "Original")
        #expect(failing.addBookmark(trackId: track.id, timestampMs: 42, title: nil, note: nil) == nil)
        #expect(working.bookmarks(forTrack: track.id).isEmpty)
        #expect(working.setTrackNote(trackId: track.id, content: "Retried"))
        #expect(working.note(forTrack: track.id)?.content == "Retried")
    }

    @Test("notes and bookmarks survive closing and reopening an on-disk store")
    func coldStoreReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.sqlite")
        let id: UUID = try autoreleasepool {
            let container = try makeModelContainer(storeURL: url)
            let track = try seedTrack(container)
            let service = NotesService(modelContainer: container, enabledProvider: { true })
            #expect(service.setTrackNote(trackId: track.id, content: "Cold restart note"))
            #expect(service.addBookmark(trackId: track.id, timestampMs: 63.8, title: "Verse", note: nil) != nil)
            return track.id
        }
        let reopened = try makeModelContainer(storeURL: url)
        let readOnly = NotesService(modelContainer: reopened, enabledProvider: { false })
        #expect(readOnly.note(forTrack: id)?.content == "Cold restart note")
        #expect(readOnly.bookmarks(forTrack: id).first?.timestampMs == 63.8)
        #expect(readOnly.searchNotes(query: "restart").count == 1)
        #expect(!readOnly.setTrackNote(trackId: id, content: "Lost"))
        #expect(readOnly.lastError != nil)
    }

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
    @Test("saved drafts survive service recreation and bookmark changes; invalid times fail")
    func persistedDraftAndBookmarkValidation() throws {
        let container = try makeContainer()
        let service = NotesService(modelContainer: container, enabledProvider: { true })
        let track = try seedTrack(container)
        #expect(service.setTrackNote(trackId: track.id, content: "Listen again"))
        let id = try #require(service.addBookmark(trackId: track.id, timestampMs: 63.8, title: "Verse", note: nil))
        #expect(service.updateBookmark(id: id, title: "Chorus", note: "Keep this"))
        let restored = NotesService(modelContainer: container, enabledProvider: { true })
        #expect(restored.note(forTrack: track.id)?.content == "Listen again")
        #expect(restored.bookmarks(forTrack: track.id).first?.timestampMs == 63.8)
        #expect(restored.bookmarks(forTrack: track.id).first?.title == "Chorus")
        for time in [-1.0, Double.nan, Double.infinity, Double.greatestFiniteMagnitude] {
            #expect(service.addBookmark(trackId: track.id, timestampMs: time, title: nil, note: nil) == nil)
            #expect(service.lastError != nil)
        }
        #expect(service.bookmarks(forTrack: track.id).count == 1)
        #expect(restored.searchNotes(query: "again").count == 1)
    }

}
