import Foundation
import Testing
@testable import Muses

@Suite("Public structured music catalog")
struct PublicMusicCatalogTests {
    @Test func podcastRowsUseExplicitWatchType() throws {
        let endpoint: [String: Any] = ["watchEndpoint": ["videoId": "abcdefghijk", "watchEndpointMusicSupportedConfigs": ["watchEndpointMusicConfig": ["musicVideoType": "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"]]]]
        let episode: [String: Any] = ["musicMultiRowListItemRenderer": ["title": ["runs": [["text": "Episode"]]], "onTap": endpoint,
            "menu": row("ABCDEFGHIJK"), "playbackProgress": ["videoPlaybackPositionFeedbackToken": "never-read"]]]
        let page = try MusicCatalogParser.page(data([episode], continuation: true), session: UUID(), endpoint: "browse", region: "US")
        #expect(page.items.map(\.kind) == [.episode])
        #expect(page.items.map(\.id) == ["video:abcdefghijk"])
        #expect(page.next != nil)
    }

    private func row(_ id: String = "abcdefghijk", type: String = "MUSIC_VIDEO_TYPE_ATV") -> [String: Any] {
        ["musicResponsiveListItemRenderer": ["flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Song", "navigationEndpoint": ["watchEndpoint": ["videoId": id, "watchEndpointMusicSupportedConfigs": ["watchEndpointMusicConfig": ["musicVideoType": type]]]]]]]]]]]]
    }
    private func data(_ rows: [[String: Any]], continuation: Bool = false) throws -> Data {
        var shelf: [String: Any] = ["contents": rows]
        if continuation { shelf["continuations"] = [["nextContinuationData": ["continuation": "opaque-test-token"]]] }
        return try JSONSerialization.data(withJSONObject: ["contents": ["sectionListRenderer": ["contents": [["musicShelfRenderer": shelf]]]]])
    }

    @Test func sourceTypeAndIdentity() throws {
        let page = try MusicCatalogParser.page(data([row(), row(), row("ABCDEFGHIJK", type: "MUSIC_VIDEO_TYPE_OMV"), row("12345678901", type: "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"), row("bad"), row("01234567890", type: "NEW_UNKNOWN_TYPE")]), session: UUID(), endpoint: "search", region: "US")
        #expect(page.items.map(\.kind) == [.song, .video, .episode])
        #expect(page.items.map(\.id) == ["video:abcdefghijk", "video:ABCDEFGHIJK", "video:12345678901"])
        #expect(page.items.first?.artists.isEmpty == true)
    }

    @Test func browsePreservesOccurrencesAndCursor() throws {
        let session = UUID()
        let page = try MusicCatalogParser.page(data([row(), row()], continuation: true), session: session, endpoint: "browse", region: "GB")
        #expect(page.items.count == 2)
        #expect(page.next?.session == session)
        #expect(page.next?.endpoint == "browse")
        #expect(page.region == "GB")
    }

    @Test func unknownResponseIsNotEmptySuccess() throws {
        #expect(throws: MusicCatalogError.self) {
            try MusicCatalogParser.page(Data(#"{"contents":{"unexpectedRenderer":{}}}"#.utf8), session: UUID(), endpoint: "search", region: "US")
        }
        let empty = try MusicCatalogParser.page(data([]), session: UUID(), endpoint: "search", region: "US")
        #expect(empty.items.isEmpty)
    }

    @Test func menusCannotBecomeResults() throws {
        var first = row()
        var contents = first["musicResponsiveListItemRenderer"] as! [String: Any]
        contents["menu"] = row("ABCDEFGHIJK")
        first["musicResponsiveListItemRenderer"] = contents
        let page = try MusicCatalogParser.page(data([first]), session: UUID(), endpoint: "search", region: "US")
        #expect(page.items.count == 1)
    }

    @Test func independentArtistAndReleaseEvidence() throws {
        func browse(_ id: String, _ type: String?) -> [String: Any] {
            var value: [String: Any] = ["browseId": id]
            if let type { value["browseEndpointContextSupportedConfigs"] = ["browseEndpointContextMusicConfig": ["pageType": type]] }
            return ["browseEndpoint": value]
        }
        var first = row()
        var contents = first["musicResponsiveListItemRenderer"] as! [String: Any]
        var columns = contents["flexColumns"] as! [[String: Any]]
        let runs: [[String: Any]] = [
            ["text": "Same name", "navigationEndpoint": browse("UCone", "MUSIC_PAGE_TYPE_ARTIST")],
            ["text": "Same name", "navigationEndpoint": browse("UCtwo", "MUSIC_PAGE_TYPE_ARTIST")],
            ["text": "Uploader", "navigationEndpoint": browse("UCuploader", nil)],
            ["text": "Release", "navigationEndpoint": browse("MPREone", "MUSIC_PAGE_TYPE_ALBUM")],
            ["text": "Release", "navigationEndpoint": browse("MPREtwo", "MUSIC_PAGE_TYPE_ALBUM")]
        ]
        columns.append(["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": runs]]])
        contents["flexColumns"] = columns
        first["musicResponsiveListItemRenderer"] = contents
        let page = try MusicCatalogParser.page(data([first]), session: UUID(), endpoint: "search", region: "US")
        let item = try #require(page.items.first)
        #expect(item.artists.map(\.id) == ["browse:UCone", "browse:UCtwo"])
        #expect(item.releases.map(\.id) == ["browse:MPREone", "browse:MPREtwo"])
        #expect(item.channels.map(\.id) == ["browse:UCuploader"])
    }

    @Test func cursorResetAndAnonymousRequests() async throws {
        let response = try data([row()], continuation: true)
        let provider = PublicMusicCatalogProvider { request in
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            if request.httpMethod != "POST" { return Data(#"{"INNERTUBE_CLIENT_VERSION":"1.20260915.14.00"}"#.utf8) }
            let body = try #require(request.httpBody)
            #expect(!String(decoding: body, as: UTF8.self).contains("visitorData"))
            return response
        }
        let page = try await provider.search("song", kind: nil)
        let cursor = try #require(page.next)
        _ = try await provider.next(cursor)
        await provider.reset()
        await #expect(throws: MusicCatalogError.self) { try await provider.next(cursor) }
    }

    @Test func cancellationDoesNotPublish() async throws {
        let response = try data([row()])
        let provider = PublicMusicCatalogProvider { request in
            if request.httpMethod != "POST" { return Data(#"{"INNERTUBE_CLIENT_VERSION":"1.20260915.14.00"}"#.utf8) }
            withUnsafeCurrentTask { $0?.cancel() }
            return response
        }
        let task = Task { try await provider.search("song", kind: nil) }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("Real public search, continuation and album browse", .enabled(if: ProcessInfo.processInfo.environment["MUSES_TEST_PUBLIC_CATALOG"] == "1"))
    func liveCatalog() async throws {
        let provider = PublicMusicCatalogProvider()
        let overview = try await provider.search("Bruno Mars", kind: nil)
        #expect(!overview.items.isEmpty)
        #expect(overview.filters.contains { $0.kind == .song })
        let songs = try await provider.search("Bruno Mars", kind: .song)
        #expect(!songs.items.isEmpty)
        #expect(songs.items.allSatisfy { $0.kind == .song })
        let cursor = try #require(songs.next)
        let more = try await provider.next(cursor)
        #expect(!more.items.isEmpty)
        #expect(Set(more.items.map(\.id)) != Set(songs.items.map(\.id)))
        let albums = try await provider.search("Bruno Mars", kind: .album)
        let album = try #require(albums.items.first)
        #expect(album.kind == .album)
        let recommended = try await provider.recommendations(after: "th92jw2CFOA")
        #expect(!recommended.isEmpty)
        #expect(recommended.allSatisfy { $0.kind == .song && $0.id != "video:th92jw2CFOA" })
        let tracks = try await provider.browse(album.id)
        #expect(!tracks.items.isEmpty)
        #expect(tracks.items.allSatisfy { $0.kind == .song || $0.kind == .video })
        let shows = try await provider.search("NPR", kind: .podcast)
        let show = try #require(shows.items.first)
        #expect(show.kind == .podcast)
        let episodes = try await provider.browse(show.id)
        #expect(!episodes.items.isEmpty)
        #expect(episodes.items.allSatisfy { $0.kind == .episode })
    }
}
