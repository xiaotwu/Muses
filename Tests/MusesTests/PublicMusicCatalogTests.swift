import Foundation
import Testing
@testable import Muses

@Suite("Public structured music catalog")
struct PublicMusicCatalogTests {
    @Test func albumHeaderPreservesCreditProvenance() throws {
        func credit(_ id: String, type: String = "MUSIC_PAGE_TYPE_ARTIST") -> [String: Any] {
            ["text": "Same name", "navigationEndpoint": ["browseEndpoint": [
                "browseId": id, "browseEndpointContextSupportedConfigs": [
                    "browseEndpointContextMusicConfig": ["pageType": type]]]]]
        }
        let header: [String: Any] = ["musicResponsiveHeaderRenderer": [
            "title": ["simpleText": "Album"], "subtitle": ["simpleText": "Album · 2016"],
            "straplineTextOne": ["runs": [credit("UCone"), credit("UCtwo"), credit("UCone"),
                                              credit("UCchannel", type: "UNKNOWN")]]]]
        let payload = try data([header, row()])
        let page = try MusicCatalogParser.page(payload, session: UUID(), endpoint: "browse", region: "US")
        #expect(page.metadata?.title == "Album")
        #expect(page.metadata?.artists.map(\.id) == ["browse:UCone", "browse:UCtwo"])
        #expect(page.items.first?.artists.isEmpty == true)
        #expect(page.items.first?.playableEntry?.uploader == nil)
        let search = try MusicCatalogParser.page(payload, session: UUID(), endpoint: "search", region: "US")
        #expect(search.metadata == nil)
        let related = try data([["musicCarouselShelfRenderer": ["contents": [header]]], row()])
        #expect(try MusicCatalogParser.page(related, session: UUID(), endpoint: "browse", region: "US").metadata == nil)
    }

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

    @Test("episodes are browse content, not a top-level search filter")
    func searchableKindsExcludeEpisodes() {
        #expect(MusicCatalogKind.searchableCases == [.song, .video, .album, .artist, .playlist, .podcast])
        #expect(!MusicCatalogKind.searchableCases.contains(.episode))
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

    @Test("locale is explicit in requests, pages, cache scope, and cursors")
    func localeScope() async throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "contents": ["sectionListRenderer": ["contents": [
                ["chipCloudRenderer": ["chips": [
                    ["chipCloudChipRenderer": [
                        "text": ["runs": [["text": "專輯"]]],
                        "navigationEndpoint": ["searchEndpoint": [
                            "params": "source-filter"
                        ]]
                    ]]
                ]]],
                ["musicShelfRenderer": [
                    "contents": [row()],
                    "continuations": [["nextContinuationData": [
                        "continuation": "opaque-test-token"
                    ]]]
                ]]
            ]]]
        ])
        let provider = PublicMusicCatalogProvider(
            region: "gb", language: "zh_Hant") { request in
                if request.httpMethod != "POST" {
                    return Data(#"{"INNERTUBE_CLIENT_VERSION":"1.20260915.14.00"}"#.utf8)
                }
                let body = try #require(request.httpBody)
                let object = try #require(
                    JSONSerialization.jsonObject(with: body) as? [String: Any])
                let context = try #require(object["context"] as? [String: Any])
                let client = try #require(context["client"] as? [String: Any])
                #expect(client["hl"] as? String == "zh-Hant")
                #expect(client["gl"] as? String == "GB")
                return response
            }
        let page = try await provider.search("歌手", kind: nil)
        #expect(page.region == "GB" && page.language == "zh-Hant")
        #expect(page.filters.map(\.kind) == [.album])
        let cursor = try #require(page.next)
        #expect(cursor.region == "GB" && cursor.language == "zh-Hant")
        let wrongLocale = MusicCatalogCursor(
            session: cursor.session, endpoint: cursor.endpoint,
            token: cursor.token, region: "US", language: "en")
        await #expect(throws: MusicCatalogError.self) {
            try await provider.next(wrongLocale)
        }
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

    @Test("Real six-category, detail, region, and language matrix",
          .enabled(if: ProcessInfo.processInfo.environment[
            "MUSES_TEST_PUBLIC_CATALOG"] == "1"))
    func liveCatalogMatrix() async throws {
        let provider = PublicMusicCatalogProvider(region: "US", language: "en")
        var pages: [MusicCatalogKind: MusicCatalogPage] = [:]
        for kind in [MusicCatalogKind.song, .video, .album, .artist, .playlist] {
            let page = try await provider.search("Bruno Mars", kind: kind)
            #expect(!page.items.isEmpty, "Live category: \(kind.rawValue)")
            #expect(page.items.allSatisfy { $0.kind == kind })
            #expect(page.region == "US" && page.language == "en")
            pages[kind] = page
        }
        for kind in [MusicCatalogKind.album, .artist, .playlist] {
            let item = try #require(pages[kind]?.items.first)
            let detail = try await provider.browse(item.id)
            #expect(!(detail.items + detail.relatedItems).isEmpty)
            #expect(detail.region == "US" && detail.language == "en")
        }

        let podcastPage = try await provider.search("NPR", kind: .podcast)
        let podcast = try #require(podcastPage.items.first)
        #expect(podcast.kind == .podcast)
        let podcastDetail = try await provider.browse(podcast.id)
        #expect(!podcastDetail.items.isEmpty)
        #expect(podcastDetail.items.allSatisfy { $0.kind == .episode })

        let charts = try await provider.browse("browse:FEmusic_charts")
        #expect(!(charts.items + charts.relatedItems).isEmpty)
        #expect(charts.region == "US" && charts.language == "en")

        let localized = PublicMusicCatalogProvider(
            region: "TW", language: "zh-Hant")
        let overview = try await localized.search("周杰倫", kind: nil)
        #expect(overview.region == "TW" && overview.language == "zh-Hant")
        #expect(overview.filters.contains { $0.kind == .album })
        let albums = try await localized.search("周杰倫", kind: .album)
        #expect(!albums.items.isEmpty)
        #expect(albums.items.allSatisfy { $0.kind == .album })
        #expect(albums.region == "TW" && albums.language == "zh-Hant")
        let localizedCharts = try await localized.browse(
            "browse:FEmusic_charts")
        #expect(!(localizedCharts.items + localizedCharts.relatedItems).isEmpty)
        #expect(localizedCharts.region == "TW"
                && localizedCharts.language == "zh-Hant")
    }
}
