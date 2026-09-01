import Foundation
import Testing
import MusesWebHomeProtocol
@testable import MusesWebHomeCore

@Suite("Web Home renderer whitelist")
struct WebHomePayloadParserTests {
    private let parser = WebHomePayloadParser()
    private let channelID = "UC1234567890123456789012"

    @Test("supported carousel, shelf, grid, quick picks normalize without unknown renderers")
    func supportedRenderers() throws {
        let data = try fixture("supported-home")
        let sections = try parser.parse(data)

        #expect(sections.count == 4)
        #expect(Set(sections.map(\.layout))
                == Set([.carousel, .musicShelf, .grid, .quickPicks]))
        let carousel = try #require(sections.first { $0.layout == .carousel })
        #expect(carousel.items.count == 1) // duplicate stable media identity removed
        #expect(carousel.items.first?.identity
                == WebHomeEndpoint(kind: .video, identifier: "video_one"))
        #expect(carousel.items.first?.browseEndpoint
                == WebHomeEndpoint(kind: .playlist, identifier: "RDAMVMvideo_one"))
        #expect(carousel.items.first?.artworkURLs
                == ["https://i.ytimg.com/vi/video_one/mqdefault.jpg"])
        #expect(carousel.continuationToken == "VOLATILE_CAROUSEL_TOKEN")

        let shelf = try #require(sections.first { $0.layout == .musicShelf })
        #expect(shelf.items.count == 1) // missing stable identity skipped
        #expect(shelf.items.first?.availability == .unavailable)

        let grid = try #require(sections.first { $0.layout == .grid })
        #expect(grid.items.first?.identity
                == WebHomeEndpoint(kind: .browse, identifier: "MPREb_album_one"))
        #expect(grid.items.first?.playEndpoint == nil)
    }

    @Test("section identity is endpoint based and independent of display title")
    func stableSectionIdentity() throws {
        let original = try fixture("supported-home")
        let changed = Data(
            String(decoding: original, as: UTF8.self)
                .replacingOccurrences(of: "Made for you", with: "Renamed editorial shelf")
                .utf8)

        let before = try parser.parse(original)
        let after = try parser.parse(changed)

        #expect(before.map(\.id) == after.map(\.id))
        #expect(before.map(\.title) != after.map(\.title))
    }

    @Test("continuation shelf only emits its whitelisted token field")
    func continuationShelf() throws {
        let sections = try parser.parse(fixture("supported-continuation"))
        let section = try #require(sections.first)

        #expect(section.layout == .continuationShelf)
        #expect(section.items.first?.playEndpoint
                == WebHomeEndpoint(kind: .video, identifier: "next_video"))
        #expect(section.continuationToken == "VOLATILE_NEXT_TOKEN")
    }

    @Test("unknown-only and excessive identity drift fail closed")
    func driftFailsClosed() throws {
        #expect(throws: WebHomeCoreError.code(.shapeChanged)) {
            try parser.parse(fixture("unknown-only"))
        }
        #expect(throws: WebHomeCoreError.code(.shapeChanged)) {
            try parser.parse(fixture("shape-drift"))
        }
    }

    @Test("command returns only normalized protocol values after exact identity check")
    func commandNormalizesPayload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muses-web-command-\(UUID().uuidString)", isDirectory: true)
        let exporter = ParserTestCookieExporter()
        let cookieManager = try WebHomeCookieJarManager(
            rootDirectory: root, exporter: exporter)
        let transport = ParserTestTransport(responses: [
            transportResponse(bootstrapHTML),
            transportResponse(identityJSON),
            transportResponse(try fixture("supported-home"))
        ])
        let command = WebHomeCommand(
            cookieManager: cookieManager,
            sessionClient: WebHomeSessionClient(transport: transport))
        let response = await command.execute(WebHomeRequest(
            action: .fetchHome,
            expectedChannelID: channelID,
            cookieSource: WebHomeCookieSourceDescriptor(browserName: "safari"),
            locale: "en-US",
            region: "US"))

        #expect(response.capability == .available)
        #expect(response.channelID == channelID)
        #expect(response.sections.count == 4)
        #expect(response.error == nil)
        let encoded = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        #expect(!encoded.contains("rawPrivateField"))
        #expect(!encoded.contains("secret"))
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/WebHome"))
        return try Data(contentsOf: url)
    }

    private var bootstrapHTML: Data {
        Data("""
        <html><script>window.ytcfg={"INNERTUBE_API_KEY":"key",
        "INNERTUBE_CLIENT_VERSION":"1.20260829.00.00",
        "VISITOR_DATA":"visitor"};</script></html>
        """.utf8)
    }

    private var identityJSON: Data {
        try! JSONSerialization.data(withJSONObject: [
            "actions": [["popup": [
                "activeAccountHeaderRenderer": ["channelId": channelID]
            ]]]
        ])
    }

    private func transportResponse(_ data: Data) -> WebHomeTransportResponse {
        WebHomeTransportResponse(
            data: data, statusCode: 200,
            finalURL: URL(string: "https://music.youtube.com/"))
    }
}

private actor ParserTestCookieExporter: YTDlpCookieExporting {
    func export(browserSpecification: String, to destination: URL) async throws {
        try Data("# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\tTRUE\t0\tSAPISID\tsecret\n".utf8)
            .write(to: destination)
    }
}

private actor ParserTestTransport: WebHomeTransport {
    private var responses: [WebHomeTransportResponse]

    init(responses: [WebHomeTransportResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> WebHomeTransportResponse {
        guard !responses.isEmpty else { throw URLError(.notConnectedToInternet) }
        return responses.removeFirst()
    }
}
