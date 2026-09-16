import Foundation
import Testing
@testable import Muses

@Suite("Browse navigation history")
struct BrowseNavigationHistoryTests {
    @Test func branchingAndDetails() {
        var history = BrowseNavigationHistory()
        let playlist = BrowseRoute.playlist(UUID())
        history.visit(.section(.playlists))
        history.visit(playlist)
        #expect(history.back() == .section(.playlists))
        #expect(history.forward() == playlist)
        #expect(history.back() == .section(.playlists))
        history.visit(.section(.songs))
        #expect(!history.canGoForward)
        history.visit(.section(.songs))
        #expect(history.entries.count == 3)
        #expect(history.back() == .section(.playlists))
        #expect(history.back() == .section(.home))
        #expect(history.back() == nil)
    }

    @Test func deletionFallbackAndBoundedMemory() {
        var history = BrowseNavigationHistory()
        for _ in 0..<150 { history.visit(.playlist(UUID())) }
        #expect(history.entries.count == 100)
        history.replaceCurrent(.section(.playlists))
        #expect(history.entries.last == .section(.playlists))
        #expect(history.forward() == nil)
    }
    @Test func settingsSubpagesShareHistoryAndBranch() {
        var history = BrowseNavigationHistory()
        let category = BrowseRoute.settings("youtube", [])
        let details = BrowseRoute.settings("youtube", [.diagnostics, .identity])
        history.visit(category)
        history.visit(details)
        #expect(history.back() == category)
        #expect(history.forward() == details)
        #expect(history.back() == category)
        history.visit(.settings("appearance", []))
        #expect(!history.canGoForward)
    }

    @Test func restoredDetailsHaveAParentWithoutRestoringOldHistory() {
        var settings = BrowseNavigationHistory(initial: .settings("appearance", []))
        #expect(settings.back() == .section(.home))
        var playlist = BrowseNavigationHistory(initial: .playlist(UUID()))
        #expect(playlist.back() == .section(.playlists))
        let snapshot = BrowseRouteSnapshot(route: .settings("youtube", [.account]), accountChannelID: "UCtest")
        #expect(snapshot.route(activeChannelID: nil) == .settings("youtube", []))
        let channel = BrowseRouteSnapshot(route: .channel("UCchannel"), accountChannelID: "UCowner")
        #expect(channel.route(activeChannelID: "other") == nil)
        #expect(channel.route(activeChannelID: "UCowner") == .channel("UCchannel"))
    }

}
