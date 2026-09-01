import Foundation
import Testing
import MusesWebHomeProtocol
@testable import Muses

@Suite("Web Home opt-in control plane")
@MainActor
struct WebHomeSessionControllerTests {
    @Test("default-off fetch never launches the helper")
    func defaultOffDoesNotLaunch() async {
        let defaults = makeDefaults()
        let recorder = WebHomeRequestRecorder()
        let controller = makeController(defaults: defaults, recorder: recorder)

        let result = await controller.fetch(for: input())

        #expect(await recorder.requests.isEmpty)
        #expect(result.webSnapshot == nil)
        #expect(result.failures.first?.code == .disabled)
        #expect(!controller.isEnabled)
    }

    @Test("dedicated consent only records configuration until an explicit probe")
    func consentDoesNotReadCookies() async throws {
        let defaults = makeDefaults()
        defaults.set(YTCookieSource.file.rawValue, forKey: PrefKey.ytCookieSource)
        defaults.set("/private/playback-cookies.txt", forKey: PrefKey.ytCookiePath)
        let recorder = WebHomeRequestRecorder(response: probeResponse())
        let controller = makeController(defaults: defaults, recorder: recorder)

        try controller.prepareDefaultBrowserConsent()
        #expect(await recorder.requests.isEmpty)
        try controller.enableUsingDefaultBrowser()
        #expect(await recorder.requests.isEmpty)
        #expect(controller.isEnabled)
        #expect(defaults.integer(forKey: PrefKey.webHomeConsentVersion)
                == WebHomePreferenceDefaults.consentVersion)
        #expect(defaults.string(forKey: PrefKey.webHomeBrowserSource) == "safari")
        #expect(defaults.string(forKey: PrefKey.ytCookieSource) == "file")
        #expect(defaults.string(forKey: PrefKey.ytCookiePath)
                == "/private/playback-cookies.txt")

        await controller.probeSession()
        let requests = await recorder.requests
        #expect(requests.count == 1)
        #expect(requests.first?.action == .probeSession)
        #expect(requests.first?.expectedChannelID == "UC_expected")
        #expect(requests.first?.cookieSource.browserName == "safari")
        #expect(requests.first?.cookieSource.filePath == nil)
        if case .available = controller.status {} else {
            Issue.record("Expected an available probe result")
        }
    }

    @Test("normalized snapshot does not persist a continuation token")
    func continuationTokenStaysVolatile() async throws {
        let defaults = makeDefaults()
        let fetchedAt = Date()
        let response = WebHomeResponse(
            channelID: "UC_expected",
            fetchedAt: fetchedAt,
            expiresAt: fetchedAt.addingTimeInterval(30 * 60),
            capability: .available,
            sections: [WebHomeSection(
                id: "quick-picks",
                title: "Quick picks",
                layout: .quickPicks,
                items: [WebHomeItem(
                    identity: WebHomeEndpoint(kind: .video, identifier: "video-1"),
                    title: "Song",
                    playEndpoint: WebHomeEndpoint(kind: .video, identifier: "video-1"))],
                continuationToken: "SECRET_CONTINUATION_TOKEN")])
        let recorder = WebHomeRequestRecorder(response: response)
        let controller = makeController(
            defaults: defaults,
            recorder: recorder,
            resolution: supported(.firefox))
        try controller.prepareDefaultBrowserConsent()
        try controller.enableUsingDefaultBrowser()

        let result = await controller.fetch(for: input())
        let snapshot = try #require(result.webSnapshot)
        let encoded = try JSONEncoder().encode(snapshot)
        let text = String(decoding: encoded, as: UTF8.self)

        #expect(snapshot.expiresAt == fetchedAt.addingTimeInterval(15 * 60))
        #expect(snapshot.sections.first?.items.first?.id == "yt:video:video-1")
        #expect(!text.contains("SECRET_CONTINUATION_TOKEN"))
        #expect(controller.hasContinuation(for: "quick-picks"))
    }

    @Test("exact OAuth channel mismatch rejects the response")
    func responseChannelMustMatchExactly() async throws {
        let defaults = makeDefaults()
        let recorder = WebHomeRequestRecorder(response: WebHomeResponse(
            channelID: "UC_other",
            fetchedAt: Date(),
            capability: .available,
            sections: []))
        let controller = makeController(
            defaults: defaults,
            recorder: recorder,
            resolution: supported(.chrome))
        try controller.prepareDefaultBrowserConsent()
        try controller.enableUsingDefaultBrowser()

        let result = await controller.fetch(for: input())

        #expect(result.webSnapshot == nil)
        #expect(result.failures.first?.code == .accountMismatch)
        #expect(!result.cacheDirectives.storeWeb)
        #expect(controller.status == .accountMismatch)
    }

    @Test("helper fetch errors are not rewritten as account mismatches")
    func fetchErrorPreservesItsCode() async throws {
        let defaults = makeDefaults()
        let recorder = WebHomeRequestRecorder(response: WebHomeResponse(
            capability: .unavailable,
            error: WebHomeError(code: .shapeChanged)))
        let controller = makeController(defaults: defaults, recorder: recorder)
        try controller.prepareDefaultBrowserConsent()
        try controller.enableUsingDefaultBrowser()

        let result = await controller.fetch(for: input())

        #expect(result.webSnapshot == nil)
        #expect(result.failures.first?.code == .shapeChanged)
        #expect(controller.status == .shapeChanged)
        #expect(!result.cacheDirectives.storeWeb)
    }

    @Test("disable revokes consent and cancels the active helper")
    func disableRevokesConsent() async throws {
        let defaults = makeDefaults()
        let recorder = WebHomeRequestRecorder()
        let controller = makeController(defaults: defaults, recorder: recorder)
        try controller.prepareDefaultBrowserConsent()
        try controller.enableUsingDefaultBrowser()

        await controller.disableAndClearTemporarySession()

        #expect(!controller.isEnabled)
        #expect(defaults.integer(forKey: PrefKey.webHomeConsentVersion) == 0)
        #expect(!defaults.bool(forKey: PrefKey.webHomeDefaultBrowserConsent))
        #expect(defaults.string(forKey: PrefKey.webHomeBrowserSource) == "")
        #expect(controller.approvedBrowserSource == nil)
        #expect(await recorder.cancelCount == 1)
    }

    @Test("continuation uses only the in-memory token chain")
    func continuationIsProcessLocal() async throws {
        let defaults = makeDefaults()
        let now = Date()
        let first = WebHomeResponse(
            channelID: "UC_expected", fetchedAt: now, capability: .available,
            sections: [WebHomeSection(
                id: "shelf", title: "Shelf", layout: .carousel,
                items: [videoItem("first")], continuationToken: "TOKEN_ONE")])
        let next = WebHomeResponse(
            channelID: "UC_expected", fetchedAt: now, capability: .available,
            sections: [WebHomeSection(
                id: "next", title: "More", layout: .continuationShelf,
                items: [videoItem("second")], continuationToken: "TOKEN_TWO")])
        let recorder = WebHomeRequestRecorder(responses: [first, next])
        let controller = makeController(defaults: defaults, recorder: recorder)
        try controller.prepareDefaultBrowserConsent()
        try controller.enableUsingDefaultBrowser()

        _ = await controller.fetch(for: input())
        let items = try await controller.fetchContinuation(for: "shelf")
        let requests = await recorder.requests

        #expect(items.first?.id == "yt:video:second")
        #expect(requests.map(\.action) == [.fetchHome, .fetchContinuation])
        #expect(requests.last?.continuationHandle == "TOKEN_ONE")
        #expect(controller.hasContinuation(for: "shelf"))
        #expect(defaults.dictionaryRepresentation().values
            .allSatisfy { !String(describing: $0).contains("TOKEN_") })
    }

    @Test("unsupported default browser cannot create Web Home consent")
    func unsupportedDefaultBrowserIsRejected() async {
        let defaults = makeDefaults()
        let recorder = WebHomeRequestRecorder()
        let controller = makeController(
            defaults: defaults,
            recorder: recorder,
            resolution: .unsupported(
                applicationName: "Arc",
                bundleIdentifier: "company.thebrowser.Browser"))

        do {
            try controller.prepareDefaultBrowserConsent()
            Issue.record("Expected the unsupported browser to be rejected")
        } catch let error as WebHomeConfigurationError {
            #expect(error == .defaultBrowserUnsupported)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(!controller.isEnabled)
        #expect(await recorder.requests.isEmpty)
        #expect(defaults.string(forKey: PrefKey.webHomeBrowserSource) == "")
    }

    @Test("cancelled probe restores the previous status instead of claiming a timeout")
    func cancelledProbeDoesNotShowTimeout() async throws {
        let defaults = makeDefaults()
        let callCount = CallCounter()
        let controller = WebHomeSessionController(
            buildEnabled: true,
            defaults: defaults,
            currentChannelIDProvider: { "UC_expected" },
            executeRequest: { request in
                let call = await callCount.increment()
                if call == 1 {
                    return WebHomeResponse(
                        channelID: "UC_expected",
                        fetchedAt: Date(),
                        capability: .available)
                }
                throw CancellationError()
            })

        try controller.prepareDefaultBrowserConsent()
        try controller.enableUsingDefaultBrowser()
        await controller.probeSession()
        guard case .available = controller.status else {
            Issue.record("Expected first probe to be available")
            return
        }

        await controller.probeSession()
        if case .unavailable(let code) = controller.status {
            Issue.record("Cancelled probe leaked \(code) into the visible status")
        }
        guard case .available = controller.status else {
            Issue.record("Cancelled probe should restore the last available status")
            return
        }
        // A cancel before any success must not show a timeout either
        let freshDefaults = makeDefaults()
        let freshController = WebHomeSessionController(
            buildEnabled: true,
            defaults: freshDefaults,
            currentChannelIDProvider: { "UC_expected" },
            executeRequest: { _ in throw CancellationError() })
        try freshController.prepareDefaultBrowserConsent()
        try freshController.enableUsingDefaultBrowser()
        await freshController.probeSession()
        #expect(freshController.status == .closed)
    }

    @Test("confirmation pins the shown browser until reconnect")
    func confirmedBrowserDoesNotSwitchSilently() async throws {
        let defaults = makeDefaults()
        let recorder = WebHomeRequestRecorder(response: probeResponse())
        let resolution = BrowserResolutionBox(supported(.safari))
        let controller = makeController(
            defaults: defaults,
            recorder: recorder,
            resolveDefaultBrowser: { resolution.value })

        try controller.prepareDefaultBrowserConsent()
        resolution.value = supported(.chrome)
        controller.refreshDefaultBrowserSource()
        try controller.enableUsingDefaultBrowser()
        await controller.probeSession()

        let requests = await recorder.requests
        #expect(requests.first?.cookieSource.browserName == "safari")
        #expect(controller.approvedBrowserSource == .safari)
        #expect(defaults.string(forKey: PrefKey.webHomeBrowserSource) == "safari")
    }

    private func input() -> HomeDiscoveryInput {
        HomeDiscoveryInput(
            topArtistNames: [], recentlyPlayedArtistNames: [], likedArtistNames: [],
            timeBand: .morning, hour: 8,
            scope: .account(channelID: "UC_expected"))
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "WebHomeSessionControllerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.register(defaults: WebHomePreferenceDefaults.values)
        return defaults
    }

    private func makeController(
        defaults: UserDefaults,
        recorder: WebHomeRequestRecorder,
        resolution: DefaultBrowserCookieSourceResolution = .supported(
            source: .safari,
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"),
        resolveDefaultBrowser: WebHomeSessionController.ResolveDefaultBrowser? = nil
    ) -> WebHomeSessionController {
        WebHomeSessionController(
            buildEnabled: true,
            defaults: defaults,
            currentChannelIDProvider: { "UC_expected" },
            resolveDefaultBrowser: resolveDefaultBrowser ?? { resolution },
            executeRequest: { request in
                try await recorder.execute(request)
            },
            cancelRequest: {
                await recorder.cancel()
            })
    }

    private func supported(
        _ source: WebHomeBrowserSource
    ) -> DefaultBrowserCookieSourceResolution {
        let bundleIdentifier = switch source {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .firefox: "org.mozilla.firefox"
        }
        return .supported(
            source: source,
            applicationName: source.displayName,
            bundleIdentifier: bundleIdentifier)
    }

    private func probeResponse() -> WebHomeResponse {
        WebHomeResponse(
            channelID: "UC_expected",
            fetchedAt: Date(),
            capability: .available)
    }


    private func videoItem(_ id: String) -> WebHomeItem {
        WebHomeItem(
            identity: WebHomeEndpoint(kind: .video, identifier: id),
            title: id,
            playEndpoint: WebHomeEndpoint(kind: .video, identifier: id))
    }
}

@MainActor
private final class BrowserResolutionBox {
    var value: DefaultBrowserCookieSourceResolution

    init(_ value: DefaultBrowserCookieSourceResolution) {
        self.value = value
    }
}

private actor CallCounter {
    private var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}

private actor WebHomeRequestRecorder {
    private(set) var requests: [WebHomeRequest] = []
    private(set) var cancelCount = 0
    private var responses: [WebHomeResponse]

    init(response: WebHomeResponse = WebHomeResponse(
        capability: .unavailable,
        error: WebHomeError(code: .offline))) {
        self.responses = [response]
    }

    init(responses: [WebHomeResponse]) {
        self.responses = responses
    }

    func execute(_ request: WebHomeRequest) throws -> WebHomeResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.cannotParseResponse) }
        if responses.count == 1 { return responses[0] }
        return responses.removeFirst()
    }

    func cancel() {
        cancelCount += 1
    }
}
