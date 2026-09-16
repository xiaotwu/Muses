import Foundation
import Testing
@testable import Muses

@Suite("Unified library", .serialized)
struct UnifiedLibraryTests {
    @Test("Favorites and music videos retain the original track identity")
    @MainActor func collectionFilters() {
        let song = Track(title: "Song", artist: "Artist", durationMs: 1000, youTubeId: "song", liked: true)
        let video = Track(title: "Video", artist: "Artist", durationMs: 1000, youTubeId: "video", mediaKind: .musicVideo)
        #expect(LibraryCollectionFilter.all.includes(song))
        #expect(LibraryCollectionFilter.all.includes(video))
        #expect(LibraryCollectionFilter.liked.includes(song))
        #expect(!LibraryCollectionFilter.liked.includes(video))
        #expect(LibraryCollectionFilter.musicVideos.includes(video))
        #expect(!LibraryCollectionFilter.musicVideos.includes(song))
        #expect([SidebarSection.liked, .musicVideos, .subscriptions].allSatisfy { $0.isLibrary })
    }

    @Test("Uploads resolve by exact channel ID even if another channel appears first")
    func exactChannelIdentity() async throws {
        let client = YouTubeDataAPIClient(accessTokenProvider: { "test-token" }, http: { request in
            let url = try #require(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains(.init(name: "id", value: "UCwanted")))
            #expect(query.contains(.init(name: "part", value: "contentDetails")))
            let body = #"{"items":[{"id":"UCother","contentDetails":{"relatedPlaylists":{"uploads":"UUother"}}},{"id":"UCwanted","contentDetails":{"relatedPlaylists":{"uploads":"UUwanted"}}}]}"#
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(try await client.uploadsPlaylist(channelID: "UCwanted") == "UUwanted")
    }

    @Test("Opaque page tokens survive query encoding without adding parameters")
    func opaquePageToken() async throws {
        let token = "next&part=wrong+/?="
        let client = YouTubeDataAPIClient(accessTokenProvider: { "test-token" }, http: { request in
            let url = try #require(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.filter { $0.name == "part" }.count == 1)
            #expect(query.first { $0.name == "pageToken" }?.value == token)
            return (Data(#"{"items":[],"nextPageToken":"last"}"#.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let page = try await client.playlistItemsPage(playlistId: "UUwanted", pageToken: token)
        #expect(page.items.isEmpty)
        #expect(page.nextPageToken == "last")
    }

    @Test("Encoding a subscription preserves its channel identity")
    func subscriptionRoundTrip() throws {
        let channel = YouTubeSubscription(channelId: "UCstable", title: "Same name", thumbnailURL: nil)
        let restored = try JSONDecoder().decode(YouTubeSubscription.self, from: JSONEncoder().encode(channel))
        #expect(restored.channelId == channel.channelId)
    }
}
