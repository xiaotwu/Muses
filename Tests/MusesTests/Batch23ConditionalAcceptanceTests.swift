import Foundation
import Testing
import MusesWebHomeProtocol
@testable import Muses

@Suite("Batch 23 conditional acceptance", .serialized)
struct Batch23ConditionalAcceptanceTests {
    @Test("Real account helper, mismatch, and failure without persistent credential writes",
          .enabled(if: ProcessInfo.processInfo.environment[
            "MUSES_TEST_BATCH23_ACCOUNT"] == "1"))
    @MainActor
    func realAccountBoundaries() async throws {
        let environment = ProcessInfo.processInfo.environment
        let appPath = try #require(environment["MUSES_TEST_APP_BUNDLE"])
        let bundle = try #require(Bundle(path: appPath))
        // Read the explicitly authorized test session, but keep token refresh
        // changes in memory; never mutate or copy credentials into the UI app.
        let source = KeychainStore(service: "muses.youtube.oauth")
        let memory = InMemoryKeychain()
        for account in [GoogleOAuthSession.configAccount, GoogleOAuthSession.tokensAccount] {
            if let data = source.data(for: account) { _ = memory.set(data, for: account) }
        }
        let configBundle = try #require(environment["MUSES_TEST_OAUTH_CONFIG_BUNDLE"])
        let configuredBundle = try #require(Bundle(path: configBundle))
        let config = try #require(GoogleOAuthConfig.applicationOwned(bundle: configuredBundle))
        let session = GoogleOAuthSession(keychain: memory, configProvider: { config })
        #expect(session.isConnected)
        let token = try await session.validAccessToken()
        let api = YouTubeDataAPIClient(accessTokenProvider: { token })
        let channel = try await api.channel()
        #expect(channel.id.hasPrefix("UC"))

        let client = WebHomeHelperClient(bundle: bundle)
        let browser = try #require(supportedBrowser())
        try #require(browser.rawValue == "chrome")
        let success = try await client.execute(WebHomeRequest(
            action: .fetchHome,
            expectedChannelID: channel.id,
            cookieSource: .init(browserName: browser.rawValue),
            locale: "en-US", region: "US"),
            timeout: .seconds(30))
        #expect(success.capability == .available)
        #expect(success.channelID == channel.id)
        #expect(!success.sections.isEmpty)

        let mismatch = try await client.execute(WebHomeRequest(
            action: .probeSession,
            expectedChannelID: "UC0000000000000000000000",
            cookieSource: .init(browserName: browser.rawValue),
            locale: "en-US", region: "US"),
            timeout: .seconds(30))
        #expect(mismatch.capability != .available)
        #expect(mismatch.error?.code == .accountMismatch)

        let emptyJar = FileManager.default.temporaryDirectory
            .appendingPathComponent("muses-empty-cookie-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: emptyJar) }
        try "# Netscape HTTP Cookie File\n".write(
            to: emptyJar, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: emptyJar.path)
        let failed = try await client.execute(WebHomeRequest(
            action: .probeSession,
            expectedChannelID: channel.id,
            cookieSource: .init(filePath: emptyJar.path),
            locale: "en-US", region: "US"),
            timeout: .seconds(30))
        #expect(failed.capability != .available)
        #expect(failed.error != nil)
    }

    @MainActor
    private func supportedBrowser() -> WebHomeBrowserSource? {
        switch DefaultBrowserCookieSourceDetector.resolve() {
        case .supported(let source, _, _): source
        case .unsupported, .unavailable: nil
        }
    }
}
