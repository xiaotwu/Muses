import Testing
import Foundation
@testable import Muses

@MainActor
struct CollectionPresentationMemoryTests {
    @Test func returningPreservesPresentationAndSeparatesWindows() {
        let window = CollectionPresentationMemory()
        let songs = window.entry(for: .section(.songs))
        let id = UUID()
        songs.mode = .list
        songs.focusedID = id
        songs.selection = [id]
        _ = window.entry(for: .section(.musicVideos))
        let returned = window.entry(for: .section(.songs))
        #expect(returned === songs)
        #expect(returned.mode == .list)
        #expect(returned.selection == [id])
        #expect(returned.focusedID == id)
        #expect(CollectionPresentationMemory().entry(for: .section(.songs)).mode == .stage)
    }

    @Test func boundedHistoryEvictsLeastRecentlyVisitedRoute() {
        let memory = CollectionPresentationMemory(capacity: 2)
        let firstRoute = BrowseRoute.playlist(UUID())
        let first = memory.entry(for: firstRoute)
        let kept = memory.entry(for: .section(.songs))
        _ = memory.entry(for: .section(.home))
        #expect(memory.entry(for: .section(.songs)) === kept)
        #expect(memory.entry(for: firstRoute) !== first)
    }
}
