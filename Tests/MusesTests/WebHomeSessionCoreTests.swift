import Foundation
import Darwin
import Testing
import MusesWebHomeProtocol
@testable import MusesWebHomeCore

@Suite("Web Home cookie and identity isolation")
struct WebHomeSessionCoreTests {
    private let channelID = "UC1234567890123456789012"

    @Test("temporary browser jar is 0600 inside a 0700 directory and is deleted")
    func temporaryJarPermissionsAndCleanup() async throws {
        let root = temporaryRoot()
        let exporter = RecordingCookieExporter(cookieText: cookieText)
        let manager = try WebHomeCookieJarManager(
            rootDirectory: root, exporter: exporter)

        let header = try await manager.withCookieJar(
            source: WebHomeCookieSourceDescriptor(browserName: "safari")) { jar in
                jar.header(for: "music.youtube.com")
            }
        let destination = try #require(await exporter.destination)
        let modeDuringExport = try #require(await exporter.modeDuringExport)
        let initialContents = try #require(await exporter.initialContents)
        let rootMode = try posixMode(root)

        #expect(header.contains("SAPISID="))
        #expect(initialContents == WebHomeCookieJarManager.netscapeCookieHeader)
        #expect(modeDuringExport & 0o777 == 0o600)
        #expect(rootMode & 0o777 == 0o700)
        #expect(!FileManager.default.fileExists(
            atPath: destination.deletingLastPathComponent().path))
    }

    @Test("old helper cookie workspaces are cleaned only inside the bounded root")
    func orphanCleanup() throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let old = root.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7_200)],
            ofItemAtPath: old.path)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("muses-web-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        _ = try WebHomeCookieJarManager(
            rootDirectory: root,
            exporter: RecordingCookieExporter(cookieText: cookieText))

        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        try? FileManager.default.removeItem(at: outside)
    }

    @Test("export-only yt-dlp exit is accepted only after it writes cookie data")
    func exportOnlyProcessExitUsesValidatedJar() async throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("fake-yt-dlp")
        let script = """
        #!/bin/sh
        destination=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--cookies" ]; then
            shift
            destination="$1"
          fi
          shift
        done
        printf '.youtube.com\tTRUE\t/\tTRUE\t0\tSAPISID\tsecret\n' >> "$destination"
        exit 2
        """
        try Data(script.utf8).write(to: executable)
        #expect(chmod(executable.path, S_IRWXU) == 0)

        let destination = root.appendingPathComponent("cookies.txt")
        try Data(WebHomeCookieJarManager.netscapeCookieHeader.utf8)
            .write(to: destination)
        let exporter = ProcessYTDlpCookieExporter(executableURL: executable)

        try await exporter.export(browserSpecification: "chrome", to: destination)

        let contents = try String(contentsOf: destination, encoding: .utf8)
        #expect(contents.contains("\tSAPISID\t"))

        try Data("#!/bin/sh\nexit 2\n".utf8).write(to: executable)
        #expect(chmod(executable.path, S_IRWXU) == 0)
        try Data(WebHomeCookieJarManager.netscapeCookieHeader.utf8)
            .write(to: destination)
        await expectCoreError(.cookieSourceUnavailable) {
            try await exporter.export(browserSpecification: "chrome", to: destination)
        }
    }

    @Test("an explicitly selected Netscape file is read without modification")
    func selectedFileIsReadOnly() async throws {
        let root = temporaryRoot()
        let source = root.deletingLastPathComponent()
            .appendingPathComponent("cookies-\(UUID().uuidString).txt")
        try Data(cookieText.utf8).write(to: source, options: .atomic)
        let before = try Data(contentsOf: source)
        let manager = try WebHomeCookieJarManager(
            rootDirectory: root,
            exporter: RecordingCookieExporter(cookieText: cookieText))

        _ = try await manager.withCookieJar(
            source: WebHomeCookieSourceDescriptor(filePath: source.path)) { jar in
                jar.sapisid
            }

        #expect(try Data(contentsOf: source) == before)
    }

    @Test("identity parser accepts only an explicit active or selected channel")
    func exactIdentityPaths() throws {
        let parser = WebHomeIdentityParser()
        let active = try JSONSerialization.data(withJSONObject: [
            "unrelated": ["browseId": "UC9999999999999999999999"],
            "actions": [[
                "popup": [
                    "activeAccountHeaderRenderer": ["channelId": channelID]
                ]
            ]]
        ])
        #expect(try parser.channelID(from: active) == channelID)

        let unrelatedOnly = try JSONSerialization.data(withJSONObject: [
            "contents": [["browseEndpoint": ["browseId": channelID]]]
        ])
        #expect(throws: WebHomeCoreError.code(.identityUnavailable)) {
            try parser.channelID(from: unrelatedOnly)
        }

        let currentAccountMenu = try JSONSerialization.data(withJSONObject: [
            "actions": [[
                "openPopupAction": [
                    "popup": [
                        "multiPageMenuRenderer": [
                            "header": ["activeAccountHeaderRenderer": [
                                "accountName": ["runs": [["text": "Account"]]]
                            ]],
                            "sections": [[
                                "multiPageMenuSectionRenderer": [
                                    "items": [[
                                        "compactLinkRenderer": [
                                            "navigationEndpoint": [
                                                "browseEndpoint": ["browseId": channelID]
                                            ]
                                        ]
                                    ]]
                                ]
                            ]]
                        ]
                    ]
                ]
            ]]
        ])
        #expect(try parser.channelID(from: currentAccountMenu) == channelID)

        let menuWithoutActiveHeader = try JSONSerialization.data(withJSONObject: [
            "multiPageMenuRenderer": [
                "sections": [["multiPageMenuSectionRenderer": ["items": [[
                    "compactLinkRenderer": ["navigationEndpoint": [
                        "browseEndpoint": ["browseId": channelID]
                    ]]
                ]]]]]
            ]
        ])
        #expect(throws: WebHomeCoreError.code(.identityUnavailable)) {
            try parser.channelID(from: menuWithoutActiveHeader)
        }
    }

    @Test("probe builds ephemeral authenticated requests and enforces exact OAuth match")
    func probeAndExactMatch() async throws {
        let transport = QueueWebHomeTransport(responses: [
            response(bootstrapHTML),
            response(identityJSON(channelID: channelID))
        ])
        let client = WebHomeSessionClient(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let result = try await client.execute(
            request: request(expectedChannelID: channelID),
            cookies: cookieJar)

        #expect(result.channelID == channelID)
        #expect(result.payload == nil)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "User-Agent")
            == WebHomeSessionClient.desktopWebUserAgent)
        #expect(requests[1].value(forHTTPHeaderField: "User-Agent")
            == WebHomeSessionClient.desktopWebUserAgent)
        #expect(requests[1].value(forHTTPHeaderField: "Authorization")?
            .hasPrefix("SAPISIDHASH 1700000000_") == true)
        #expect(requests[1].value(forHTTPHeaderField: "Cookie")?.contains("secret") == true)

        let mismatchTransport = QueueWebHomeTransport(responses: [
            response(bootstrapHTML),
            response(identityJSON(channelID: channelID))
        ])
        let mismatch = WebHomeSessionClient(transport: mismatchTransport)
        await expectCoreError(.accountMismatch) {
            try await mismatch.execute(
                request: request(expectedChannelID: "UC0000000000000000000000"),
                cookies: cookieJar)
        }
    }

    @Test("expired or incomplete cookie sessions fail without fetching Home")
    func missingSessionCookie() async {
        let transport = QueueWebHomeTransport(responses: [])
        let client = WebHomeSessionClient(transport: transport)
        let jar = WebHomeCookieJar(cookies: [WebHomeCookie(
            domain: ".youtube.com", path: "/", secure: true,
            expiresAt: nil, name: "SID", value: "not-sapisid")])

        await expectCoreError(.sessionExpired) {
            try await client.execute(
                request: request(expectedChannelID: channelID),
                cookies: jar)
        }
        #expect(await transport.requests.isEmpty)
    }

    private var cookieText: String {
        "# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\tTRUE\t0\tSAPISID\tsecret\n"
    }

    private var cookieJar: WebHomeCookieJar {
        WebHomeCookieJar(cookies: [WebHomeCookie(
            domain: ".youtube.com", path: "/", secure: true,
            expiresAt: nil, name: "SAPISID", value: "secret")])
    }

    private var bootstrapHTML: Data {
        Data("""
        <html><script>window.ytcfg={"INNERTUBE_API_KEY":"key",
        "INNERTUBE_CLIENT_VERSION":"1.20260829.00.00",
        "VISITOR_DATA":"visitor"};</script></html>
        """.utf8)
    }

    private func identityJSON(channelID: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "actions": [[
                "openPopupAction": [
                    "popup": [
                        "activeAccountHeaderRenderer": ["channelId": channelID]
                    ]
                ]
            ]]
        ])
    }

    private func response(_ data: Data, status: Int = 200) -> WebHomeTransportResponse {
        WebHomeTransportResponse(
            data: data, statusCode: status,
            finalURL: URL(string: "https://music.youtube.com/"))
    }

    private func request(expectedChannelID: String) -> WebHomeRequest {
        WebHomeRequest(
            action: .probeSession,
            expectedChannelID: expectedChannelID,
            cookieSource: WebHomeCookieSourceDescriptor(browserName: "safari"),
            locale: "en-US",
            region: "US")
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("muses-web-cookie-test-\(UUID().uuidString)", isDirectory: true)
    }

    private func posixMode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? Int)
    }

    private func expectCoreError<T: Sendable>(
        _ code: WebHomeErrorCode,
        operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected \(code.rawValue)")
        } catch let error as WebHomeCoreError {
            #expect(error == .code(code))
        } catch {
            Issue.record("Unexpected error: \(type(of: error))")
        }
    }
}

private actor RecordingCookieExporter: YTDlpCookieExporting {
    let cookieText: String
    private(set) var destination: URL?
    private(set) var modeDuringExport: Int?
    private(set) var initialContents: String?

    init(cookieText: String) {
        self.cookieText = cookieText
    }

    func export(browserSpecification: String, to destination: URL) async throws {
        self.destination = destination
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        modeDuringExport = attributes[.posixPermissions] as? Int
        initialContents = try String(contentsOf: destination, encoding: .utf8)
        try Data(cookieText.utf8).write(to: destination)
    }
}

private actor QueueWebHomeTransport: WebHomeTransport {
    private var responses: [WebHomeTransportResponse]
    private(set) var requests: [URLRequest] = []

    init(responses: [WebHomeTransportResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> WebHomeTransportResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.notConnectedToInternet) }
        return responses.removeFirst()
    }
}
