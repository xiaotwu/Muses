import Testing
import Foundation
@testable import Muses

@MainActor
struct CollectionPresentationMemoryTests {
    @Test func returningPreservesPresentationAndSeparatesWindows() throws {
        let suite = "Muses.CollectionPresentationTest.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = CollectionPresentationMemory(defaults: defaults)
        let otherWindow = CollectionPresentationMemory(defaults: defaults)
        let otherSongs = otherWindow.entry(for: .section(.songs))
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
        #expect(otherSongs.mode == .stage)
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

    @Test func identityOnlySnapshotSeedsNextProcess() throws {
        let suite = "Muses.CollectionPresentationTest.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let route = BrowseRoute.playlist(UUID())
        let focusedID = UUID()

        let firstProcess = CollectionPresentationMemory(defaults: defaults)
        let firstEntry = firstProcess.entry(for: route)
        firstEntry.mode = .list
        firstEntry.focusedID = focusedID
        firstEntry.selection = [focusedID]

        let nextProcess = CollectionPresentationMemory(defaults: defaults)
        let restored = nextProcess.entry(for: route)
        #expect(restored.mode == .list)
        #expect(restored.focusedID == focusedID)
        #expect(restored.selection == [focusedID])
        #expect(restored.sortOrder == nil)
    }

    @Test func nonCollectionRoutesDoNotPersistPresentation() throws {
        let suite = "Muses.CollectionPresentationTest.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let firstProcess = CollectionPresentationMemory(defaults: defaults)
        firstProcess.entry(for: .section(.home)).mode = .list
        let nextProcess = CollectionPresentationMemory(defaults: defaults)
        #expect(nextProcess.entry(for: .section(.home)).mode == .stage)
    }
}
