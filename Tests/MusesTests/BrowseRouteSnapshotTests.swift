import Foundation
import Testing
@testable import Muses

@Suite("Last browse route restoration")
struct BrowseRouteSnapshotTests {
    @Test func publicRouteRoundTrip() throws {
        let routes: [BrowseRoute] = [
            .section(.settings), .section(.songs), .playlist(UUID()), .youTubeImport(UUID()),
            .release("playlist:OLAK5uy_album"), .artist("channel:UCartist")
        ]
        for route in routes {
            let value = BrowseRouteSnapshot(route: route, accountChannelID: "UCprivate")
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(BrowseRouteSnapshot.self, from: data)
            #expect(decoded.route(activeChannelID: nil) == route)
            #expect(decoded.accountChannelID == nil)
        }
    }

    @Test func privateRoutesRequireMatchingAccount() {
        let value = BrowseRouteSnapshot(route: .section(.subscriptions), accountChannelID: "UCowner")
        #expect(value.requiresAccount)
        #expect(value.route(activeChannelID: nil) == nil)
        #expect(value.route(activeChannelID: "UCother") == nil)
        #expect(value.route(activeChannelID: "UCowner") == .section(.subscriptions))
        let unknown = BrowseRouteSnapshot(route: .section(.subscriptions), accountChannelID: nil)
        #expect(unknown.route(activeChannelID: nil) == nil)
    }

    @Test func restoredPageSeedsOnlyItsParent() {
        let route = BrowseRoute.playlist(UUID())
        var history = BrowseNavigationHistory(initial: route)
        #expect(history.entries == [.section(.playlists), route])
        #expect(history.canGoBack && !history.canGoForward)
        history.visit(route)
        #expect(history.entries == [.section(.playlists), route])
        history.visit(.section(.songs))
        #expect(history.back() == route)
    }

    @Test func malformedOrFutureValuesAreIgnored() throws {
        for json in [
            #"{"version":2,"kind":"section","value":"songs"}"#,
            #"{"version":1,"kind":"unknown","value":"songs"}"#,
            #"{"version":1,"kind":"playlist","value":"not-a-uuid"}"#,
            #"{"version":1,"kind":"section","value":"retired"}"#,
            #"{"version":1,"kind":"release","value":"album:artist:title"}"#
        ] {
            let value = try JSONDecoder().decode(BrowseRouteSnapshot.self, from: Data(json.utf8))
            #expect(value.route(activeChannelID: nil) == nil)
        }
    }

    @Test func preferenceRoundTripAndCorruptData() throws {
        let suite = "Muses.BrowseRouteTest.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = BrowseRouteSnapshot(route: .section(.albums), accountChannelID: nil)
        snapshot.save(defaults: defaults)
        #expect(BrowseRouteSnapshot.read(defaults: defaults) == snapshot)
        defaults.set(Data("invalid".utf8), forKey: BrowseRouteSnapshot.preferenceKey)
        #expect(BrowseRouteSnapshot.read(defaults: defaults) == nil)
        defaults.set(Data(repeating: 0, count: 4097), forKey: BrowseRouteSnapshot.preferenceKey)
        #expect(BrowseRouteSnapshot.read(defaults: defaults) == nil)
    }
}
