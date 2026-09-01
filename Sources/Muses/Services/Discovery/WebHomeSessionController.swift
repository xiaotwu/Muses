import Foundation
import Observation
import MusesWebHomeProtocol

enum WebHomeSessionStatus: Equatable {
    case closed
    case disabledByBuild
    case pendingConsent
    case checking
    case refreshing
    case available(checkedAt: Date)
    case expired
    case accountMismatch
    case shapeChanged
    case unavailable(HomeFetchFailureCode)
}

enum WebHomeConfigurationError: Error, Equatable {
    case disabledByBuild
    case oauthRequired
    case defaultBrowserUnavailable
    case defaultBrowserUnsupported
}

struct WebHomeContinuationError: Error, Equatable {
    let code: HomeFetchFailureCode
}

/// Composition-root-owned control plane for the optional Web Home layer.
///
/// The controller stores only consent/configuration and normalized feed data.
/// Cookie values, SAPISIDHASH, raw payloads, and continuation tokens remain in
/// the helper or this process's volatile memory and are never logged.
@MainActor
@Observable
final class WebHomeSessionController: HomeDiscoveryProvider {
    typealias ExecuteRequest = @Sendable (WebHomeRequest) async throws -> WebHomeResponse
    typealias CancelRequest = @Sendable () async -> Void
    typealias ResolveDefaultBrowser = () -> DefaultBrowserCookieSourceResolution

    private(set) var status: WebHomeSessionStatus
    private(set) var lastCheckedAt: Date?
    private(set) var defaultBrowserResolution: DefaultBrowserCookieSourceResolution

    private let defaults: UserDefaults
    private let buildEnabled: Bool
    private let currentChannelIDProvider: () -> String?
    private let resolveDefaultBrowser: ResolveDefaultBrowser
    private let executeRequest: ExecuteRequest
    private let cancelRequest: CancelRequest
    private var continuationTokensBySectionID: [String: String] = [:]
    private var pendingBrowserSource: WebHomeBrowserSource?

    var hasWebEnhancement: Bool { isEnabled }

    var isEnabled: Bool {
        buildEnabled
            && defaults.bool(forKey: PrefKey.webHomeEnabled)
            && defaults.integer(forKey: PrefKey.webHomeConsentVersion)
                == WebHomePreferenceDefaults.consentVersion
            && defaults.bool(forKey: PrefKey.webHomeDefaultBrowserConsent)
            && approvedBrowserSource != nil
    }

    var isBuildEnabled: Bool { buildEnabled }
    var hasCurrentConsent: Bool {
        defaults.integer(forKey: PrefKey.webHomeConsentVersion)
            == WebHomePreferenceDefaults.consentVersion
            && defaults.bool(forKey: PrefKey.webHomeDefaultBrowserConsent)
            && approvedBrowserSource != nil
    }

    var approvedBrowserSource: WebHomeBrowserSource? {
        guard let rawValue = defaults.string(forKey: PrefKey.webHomeBrowserSource) else {
            return nil
        }
        return WebHomeBrowserSource(rawValue: rawValue)
    }

    init(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        currentChannelIDProvider: @escaping () -> String?
    ) {
        let client = WebHomeHelperClient(bundle: bundle)
        let enabled = Self.isEnabledByBuild(in: bundle)
        let browserResolution = DefaultBrowserCookieSourceDetector.resolve()
        self.defaults = defaults
        self.buildEnabled = enabled
        self.currentChannelIDProvider = currentChannelIDProvider
        self.resolveDefaultBrowser = {
            DefaultBrowserCookieSourceDetector.resolve()
        }
        self.executeRequest = { request in
            try await client.execute(request)
        }
        self.cancelRequest = {
            await client.cancel()
        }
        self.defaultBrowserResolution = browserResolution
        self.status = enabled ? .closed : .disabledByBuild
    }

    init(
        buildEnabled: Bool,
        defaults: UserDefaults,
        currentChannelIDProvider: @escaping () -> String?,
        resolveDefaultBrowser: @escaping ResolveDefaultBrowser = {
            .supported(
                source: .safari,
                applicationName: "Safari",
                bundleIdentifier: "com.apple.Safari")
        },
        executeRequest: @escaping ExecuteRequest,
        cancelRequest: @escaping CancelRequest = {}
    ) {
        self.defaults = defaults
        self.buildEnabled = buildEnabled
        self.currentChannelIDProvider = currentChannelIDProvider
        self.resolveDefaultBrowser = resolveDefaultBrowser
        self.executeRequest = executeRequest
        self.cancelRequest = cancelRequest
        self.defaultBrowserResolution = resolveDefaultBrowser()
        self.status = buildEnabled ? .closed : .disabledByBuild
    }

    static func isEnabledByBuild(in bundle: Bundle) -> Bool {
        (bundle.object(forInfoDictionaryKey: "MusesWebHomeEnabled") as? NSNumber)?.boolValue
            ?? false
    }

    /// Resolves and freezes the source shown by the dedicated disclosure. This
    /// does not launch the browser, read a profile, or start the helper.
    func prepareDefaultBrowserConsent() throws {
        guard buildEnabled else { throw WebHomeConfigurationError.disabledByBuild }
        guard normalizedChannelID() != nil else {
            throw WebHomeConfigurationError.oauthRequired
        }
        refreshDefaultBrowserSource()
        switch defaultBrowserResolution {
        case .supported(let source, _, _):
            pendingBrowserSource = source
            status = .pendingConsent
        case .unsupported:
            pendingBrowserSource = nil
            throw WebHomeConfigurationError.defaultBrowserUnsupported
        case .unavailable:
            pendingBrowserSource = nil
            throw WebHomeConfigurationError.defaultBrowserUnavailable
        }
    }

    /// Called only after the prepared disclosure is confirmed. Probe/fetch are
    /// separate so recording consent never reads cookies by itself.
    func enableUsingDefaultBrowser() throws {
        guard buildEnabled else { throw WebHomeConfigurationError.disabledByBuild }
        guard normalizedChannelID() != nil else {
            throw WebHomeConfigurationError.oauthRequired
        }
        guard let source = pendingBrowserSource else {
            throw WebHomeConfigurationError.defaultBrowserUnavailable
        }
        defaults.set(source.rawValue, forKey: PrefKey.webHomeBrowserSource)
        defaults.set(WebHomePreferenceDefaults.consentVersion,
                     forKey: PrefKey.webHomeConsentVersion)
        defaults.set(true, forKey: PrefKey.webHomeDefaultBrowserConsent)
        defaults.set(true, forKey: PrefKey.webHomeEnabled)
        pendingBrowserSource = nil
        status = .closed
    }

    func refreshDefaultBrowserSource() {
        defaultBrowserResolution = resolveDefaultBrowser()
    }

    func cancelPendingConsent() {
        pendingBrowserSource = nil
        guard !isEnabled else { return }
        status = buildEnabled ? .closed : .disabledByBuild
    }

    func disableAndClearTemporarySession() async {
        defaults.set(false, forKey: PrefKey.webHomeEnabled)
        defaults.set(0, forKey: PrefKey.webHomeConsentVersion)
        defaults.set(false, forKey: PrefKey.webHomeDefaultBrowserConsent)
        defaults.removeObject(forKey: PrefKey.webHomeBrowserSource)
        pendingBrowserSource = nil
        continuationTokensBySectionID.removeAll(keepingCapacity: false)
        await cancelRequest()
        status = buildEnabled ? .closed : .disabledByBuild
        lastCheckedAt = nil
    }

    func accountDidChange() async {
        continuationTokensBySectionID.removeAll(keepingCapacity: false)
        await cancelRequest()
        if !buildEnabled {
            status = .disabledByBuild
        } else if !isEnabled {
            status = .closed
        } else if normalizedChannelID() == nil {
            status = .unavailable(.oauthRequired)
        } else {
            status = .closed
        }
        lastCheckedAt = nil
    }

    func probeSession() async {
        guard let request = makeRequest(action: .probeSession) else {
            applyPreflightStatus()
            return
        }
        let statusBeforeCheck = status
        status = .checking
        let interval = PerfTrace.begin("home.web.probe")
        defer { PerfTrace.end(interval) }
        do {
            let response = try await executeRequest(request)
            apply(response: response)
        } catch let error as WebHomeHelperClientError {
            status = .unavailable(error.failureCode)
        } catch is CancellationError {
            // A UI cancellation (e.g. leaving the settings page quickly) is not a session timeout; restore the
            // pre-check status so a transient label never suggests re-authorization is needed.
            status = statusBeforeCheck == .checking ? .closed : statusBeforeCheck
        } catch {
            status = .unavailable(.helperCrashed)
        }
    }

    func fetch(for input: HomeDiscoveryInput) async -> HomeFetchResult {
        let emptyBaseline = HomeFetchResult.baseline(scope: input.scope, sections: [])
            .baselineSnapshot
        guard case .account(let expectedChannelID) = input.scope else {
            return failureResult(
                baseline: emptyBaseline, code: .oauthRequired,
                capability: .signedOut)
        }
        guard expectedChannelID == normalizedChannelID() else {
            status = .accountMismatch
            return failureResult(
                baseline: emptyBaseline, code: .accountMismatch,
                capability: .rejected(reason: failureMessage(.accountMismatch)))
        }
        guard let request = makeRequest(action: .fetchHome) else {
            applyPreflightStatus()
            let code = preflightFailureCode()
            return failureResult(
                baseline: emptyBaseline, code: code,
                capability: capability(for: code))
        }

        status = .refreshing
        let interval = PerfTrace.begin("home.web.fetch")
        defer { PerfTrace.end(interval) }
        do {
            let response = try await executeRequest(request)
            if let error = response.error {
                let code = map(error.code)
                applyFailureStatus(code)
                return failureResult(
                    baseline: emptyBaseline, code: code,
                    message: error.message,
                    capability: capability(for: code, message: error.message))
            }
            guard response.channelID == expectedChannelID else {
                status = .accountMismatch
                return failureResult(
                    baseline: emptyBaseline, code: .accountMismatch,
                    capability: .rejected(reason: failureMessage(.accountMismatch)))
            }
            guard response.capability == .available,
                  let fetchedAt = response.fetchedAt else {
                status = .unavailable(.malformedResponse)
                return failureResult(
                    baseline: emptyBaseline, code: .malformedResponse,
                    capability: .unavailable(reason: failureMessage(.malformedResponse)))
            }

            let sections = normalizedSections(
                response.sections,
                channelID: expectedChannelID,
                fetchedAt: fetchedAt,
                expiresAt: response.expiresAt,
                schemaVersion: response.parserSchemaVersion)
            guard !sections.isEmpty else {
                status = .shapeChanged
                return failureResult(
                    baseline: emptyBaseline, code: .shapeChanged,
                    capability: .rejected(reason: failureMessage(.shapeChanged)))
            }
            let expiry = min(
                response.expiresAt ?? fetchedAt.addingTimeInterval(HomeFeedCache.webFreshWindow),
                fetchedAt.addingTimeInterval(HomeFeedCache.webFreshWindow))
            lastCheckedAt = fetchedAt
            status = .available(checkedAt: fetchedAt)
            PerfTrace.event("home.web.success.schema-\(max(1, response.parserSchemaVersion))")
            return HomeFetchResult(
                baselineSnapshot: emptyBaseline,
                webSnapshot: HomeSnapshot(
                    scope: input.scope,
                    sections: sections,
                    fetchedAt: fetchedAt,
                    expiresAt: expiry,
                    schemaVersion: max(1, response.parserSchemaVersion)),
                webCapability: .available(accountChannelID: expectedChannelID),
                failures: [],
                cacheDirectives: HomeCacheDirectives(
                    storeBaseline: false, storeWeb: true))
        } catch let error as WebHomeHelperClientError {
            applyFailureStatus(error.failureCode)
            return failureResult(
                baseline: emptyBaseline, code: error.failureCode,
                capability: .unavailable(reason: failureMessage(error.failureCode)))
        } catch is CancellationError {
            status = .unavailable(.timedOut)
            return failureResult(
                baseline: emptyBaseline, code: .timedOut,
                capability: .unavailable(reason: failureMessage(.timedOut)))
        } catch {
            status = .unavailable(.helperCrashed)
            return failureResult(
                baseline: emptyBaseline, code: .helperCrashed,
                capability: .unavailable(reason: failureMessage(.helperCrashed)))
        }
    }

    func more(page: Int, input: HomeDiscoveryInput) async -> [HomeSection] { [] }

    func hasContinuation(for sectionID: String) -> Bool {
        continuationTokensBySectionID[sectionID] != nil
    }

    /// Resolves one volatile continuation. The raw token is looked up by the
    /// visible section id, sent only over the one-shot IPC, then replaced with
    /// the next token in memory. Returned items are normalized values only.
    func fetchContinuation(for sectionID: String) async throws -> [DiscoveryItem] {
        guard let token = continuationTokensBySectionID[sectionID],
              let request = makeRequest(
                action: .fetchContinuation,
                continuationToken: token) else {
            throw WebHomeContinuationError(code: preflightFailureCode())
        }
        status = .refreshing
        let interval = PerfTrace.begin("home.web.continuation")
        defer { PerfTrace.end(interval) }
        do {
            let response = try await executeRequest(request)
            if let error = response.error {
                let code = map(error.code)
                applyFailureStatus(code)
                throw WebHomeContinuationError(code: code)
            }
            guard response.channelID == normalizedChannelID() else {
                status = .accountMismatch
                throw WebHomeContinuationError(code: .accountMismatch)
            }
            guard response.capability == .available else {
                status = .unavailable(.malformedResponse)
                throw WebHomeContinuationError(code: .malformedResponse)
            }
            var seen = Set<String>()
            let items = response.sections.flatMap(\.items)
                .map(normalizedItem)
                .filter { seen.insert($0.id).inserted }
            guard !items.isEmpty else {
                status = .shapeChanged
                throw WebHomeContinuationError(code: .shapeChanged)
            }
            if let next = response.sections.compactMap(\.continuationToken)
                .first(where: { !$0.isEmpty }) {
                continuationTokensBySectionID[sectionID] = next
            } else {
                continuationTokensBySectionID.removeValue(forKey: sectionID)
            }
            let checkedAt = response.fetchedAt ?? Date()
            lastCheckedAt = checkedAt
            status = .available(checkedAt: checkedAt)
            return items
        } catch let error as WebHomeContinuationError {
            throw error
        } catch let error as WebHomeHelperClientError {
            applyFailureStatus(error.failureCode)
            throw WebHomeContinuationError(code: error.failureCode)
        } catch is CancellationError {
            status = .unavailable(.timedOut)
            throw WebHomeContinuationError(code: .timedOut)
        } catch {
            status = .unavailable(.helperCrashed)
            throw WebHomeContinuationError(code: .helperCrashed)
        }
    }

    private func makeRequest(action: WebHomeAction,
                             continuationToken: String? = nil) -> WebHomeRequest? {
        guard isEnabled,
              let channelID = normalizedChannelID(),
              let source = cookieSourceDescriptor() else { return nil }
        return WebHomeRequest(
            action: action,
            expectedChannelID: channelID,
            cookieSource: source,
            locale: Locale.current.identifier,
            region: Locale.current.region?.identifier ?? "US",
            timeoutMilliseconds: 12_000,
            continuationHandle: continuationToken)
    }

    private func normalizedChannelID() -> String? {
        let value = currentChannelIDProvider()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func cookieSourceDescriptor() -> WebHomeCookieSourceDescriptor? {
        guard defaults.bool(forKey: PrefKey.webHomeDefaultBrowserConsent),
              let source = approvedBrowserSource else { return nil }
        return WebHomeCookieSourceDescriptor(browserName: source.rawValue)
    }

    private func normalizedSections(
        _ rawSections: [WebHomeSection],
        channelID: String,
        fetchedAt: Date,
        expiresAt: Date?,
        schemaVersion: Int
    ) -> [HomeSection] {
        var seenSectionIDs = Set<String>()
        return rawSections.compactMap { raw in
            guard !raw.id.isEmpty, seenSectionIDs.insert(raw.id).inserted else { return nil }
            let items = raw.items.map(normalizedItem)
            guard !items.isEmpty else { return nil }
            if let token = raw.continuationToken, !token.isEmpty {
                continuationTokensBySectionID[raw.id] = token
            } else {
                continuationTokensBySectionID.removeValue(forKey: raw.id)
            }
            return HomeSection(
                id: raw.id,
                title: raw.title,
                subtitle: raw.subtitle,
                kind: homeKind(raw.layout),
                items: items,
                status: .loaded,
                source: .signedInWeb,
                accountChannelID: channelID,
                schemaVersion: max(1, schemaVersion),
                fetchedAt: fetchedAt,
                expiresAt: expiresAt)
        }
    }

    private func normalizedItem(_ item: WebHomeItem) -> DiscoveryItem {
        DiscoveryItem.youTube(YouTubeDiscoveryCard(
            id: "\(item.identity.kind.rawValue):\(item.identity.identifier)",
            title: item.title,
            uploader: item.subtitle,
            thumbnailURL: item.artworkURLs.last,
            browseEndpoint: homeEndpoint(item.browseEndpoint),
            playEndpoint: homeEndpoint(item.playEndpoint),
            availability: homeAvailability(item.availability)))
    }

    private func homeKind(_ layout: WebHomeSectionLayout) -> HomeSectionKind {
        switch layout {
        case .musicShelf: .songGrid
        case .quickPicks: .quickPicks
        case .grid: .mixed
        case .carousel, .continuationShelf: .youTubeCarousel
        }
    }

    private func homeEndpoint(_ endpoint: WebHomeEndpoint?) -> HomeCardEndpoint? {
        guard let endpoint, !endpoint.identifier.isEmpty else { return nil }
        let kind: HomeCardEndpointKind = switch endpoint.kind {
        case .video: .video
        case .playlist: .playlist
        case .browse: .browse
        case .channel: .channel
        }
        return HomeCardEndpoint(kind: kind, identifier: endpoint.identifier)
    }

    private func homeAvailability(_ value: WebHomeAvailability) -> HomeCardAvailability {
        switch value {
        case .available: .available
        case .unavailable: .unavailable
        case .regionBlocked: .regionBlocked
        case .privateItem: .privateItem
        case .deleted: .deleted
        }
    }

    private func apply(response: WebHomeResponse) {
        if let error = response.error {
            applyFailureStatus(map(error.code))
            return
        }
        guard response.capability == .available,
              response.channelID == normalizedChannelID() else {
            status = response.channelID == nil ? .unavailable(.identityUnavailable) : .accountMismatch
            return
        }
        let checkedAt = response.fetchedAt ?? Date()
        lastCheckedAt = checkedAt
        status = .available(checkedAt: checkedAt)
    }

    private func applyPreflightStatus() {
        let code = preflightFailureCode()
        if !buildEnabled { status = .disabledByBuild }
        else if !hasCurrentConsent { status = .pendingConsent }
        else { applyFailureStatus(code) }
    }

    private func preflightFailureCode() -> HomeFetchFailureCode {
        if !isEnabled { return .disabled }
        if normalizedChannelID() == nil { return .oauthRequired }
        if cookieSourceDescriptor() == nil { return .cookieSourceUnavailable }
        return .disabled
    }

    private func applyFailureStatus(_ code: HomeFetchFailureCode) {
        PerfTrace.event("home.web.failure.\(code.rawValue)")
        switch code {
        case .sessionExpired: status = .expired
        case .accountMismatch: status = .accountMismatch
        case .shapeChanged: status = .shapeChanged
        default: status = .unavailable(code)
        }
    }

    private func failureResult(
        baseline: HomeSnapshot,
        code: HomeFetchFailureCode,
        message: String? = nil,
        capability: HomeWebCapability
    ) -> HomeFetchResult {
        HomeFetchResult(
            baselineSnapshot: baseline,
            webSnapshot: nil,
            webCapability: capability,
            failures: [HomeFetchFailure(
                layer: .web,
                code: code,
                message: message ?? failureMessage(code))],
            cacheDirectives: .preserveAll)
    }

    private func capability(for code: HomeFetchFailureCode,
                            message: String? = nil) -> HomeWebCapability {
        switch code {
        case .disabled: .notConfigured
        case .oauthRequired: .signedOut
        case .accountMismatch, .shapeChanged:
            .rejected(reason: message ?? failureMessage(code))
        default: .unavailable(reason: message ?? failureMessage(code))
        }
    }

    private func failureMessage(_ code: HomeFetchFailureCode) -> String {
        switch code {
        case .disabled:
            tr("YouTube Music Web Home is turned off.", "YouTube Music Web Home 已关闭。")
        case .oauthRequired:
            tr("Connect the matching YouTube account first.", "请先连接匹配的 YouTube 账号。")
        case .cookieSourceUnavailable:
            tr("The selected cookie source is unavailable.", "所选 Cookie 来源不可用。")
        case .sessionExpired:
            tr("The browser session has expired.", "浏览器会话已过期。")
        case .consentOrCaptchaRequired:
            tr("YouTube requires consent or a CAPTCHA in the browser.", "YouTube 要求在浏览器中完成同意或验证码。")
        case .identityUnavailable:
            tr("The Web session channel identity could not be verified.", "无法核验 Web 会话的频道身份。")
        case .accountMismatch:
            tr("The Web session does not match the connected OAuth channel.", "Web 会话与已连接的 OAuth 频道不匹配。")
        case .shapeChanged:
            tr("YouTube Music changed the Home response shape.", "YouTube Music 的首页响应结构已变化。")
        case .rateLimited:
            tr("YouTube temporarily rate-limited this request.", "YouTube 暂时限制了此请求。")
        case .offline:
            tr("The Web session is offline.", "Web 会话当前离线。")
        case .timedOut:
            tr("The Web Home helper timed out.", "Web Home Helper 已超时。")
        case .helperCrashed:
            tr("The Web Home helper stopped unexpectedly.", "Web Home Helper 意外停止。")
        case .protocolMismatch:
            tr("The app and Web Home helper versions do not match.", "App 与 Web Home Helper 版本不匹配。")
        case .responseTooLarge:
            tr("The Web Home response exceeded the safety limit.", "Web Home 响应超过安全上限。")
        case .malformedResponse:
            tr("The Web Home helper returned an invalid response.", "Web Home Helper 返回了无效响应。")
        case .baselineUnavailable:
            tr("Public Home is temporarily unavailable.", "公共首页暂不可用。")
        }
    }

    private func map(_ code: WebHomeErrorCode) -> HomeFetchFailureCode {
        switch code {
        case .disabled: .disabled
        case .oauthRequired: .oauthRequired
        case .cookieSourceUnavailable: .cookieSourceUnavailable
        case .sessionExpired: .sessionExpired
        case .consentOrCaptchaRequired: .consentOrCaptchaRequired
        case .identityUnavailable: .identityUnavailable
        case .accountMismatch: .accountMismatch
        case .shapeChanged: .shapeChanged
        case .rateLimited: .rateLimited
        case .offline: .offline
        case .timedOut, .cancelled: .timedOut
        case .helperCrashed: .helperCrashed
        case .protocolMismatch: .protocolMismatch
        case .responseTooLarge: .responseTooLarge
        case .malformedResponse: .malformedResponse
        }
    }
}
