import Foundation

@MainActor
final class AnonymousInnertubeHomeProvider: HomeDiscoveryProvider {
    private let client: any InnertubeServing
    private var continuation: String?
    private var shelfContinuations: [String: String] = [:]
    private var continuationScope: HomeFeedScope?
    private var continuationGeneration = UUID()

    init(client: any InnertubeServing) {
        self.client = client
    }

    func fetch(for input: HomeDiscoveryInput) async -> HomeFetchResult {
        continuationGeneration = UUID()
        continuationScope = input.scope
        continuation = nil
        shelfContinuations.removeAll(keepingCapacity: false)
        do {
            let page = try await client.home(continuation: nil)
            continuation = page.continuation
            shelfContinuations = page.shelfContinuations
            let now = Date()
            let snapshot = HomeSnapshot(
                scope: input.scope,
                sections: page.sections,
                fetchedAt: now,
                expiresAt: now.addingTimeInterval(HomeFeedCache.webFreshWindow),
                schemaVersion: page.parserSchemaVersion)
            return HomeFetchResult(
                baselineSnapshot: snapshot,
                webSnapshot: nil,
                webCapability: .notConfigured,
                failures: [],
                cacheDirectives: HomeCacheDirectives(storeBaseline: true, storeWeb: false))
        } catch {
            continuation = nil
            shelfContinuations.removeAll(keepingCapacity: false)
            let code = failureCode(error)
            return .baseline(
                scope: input.scope,
                sections: [],
                failures: [HomeFetchFailure(
                    layer: .baseline,
                    code: code,
                    message: failureMessage(code))])
        }
    }

    func more(page: Int, input: HomeDiscoveryInput) async -> [HomeSection] {
        guard continuationScope == input.scope, let token = continuation else { return [] }
        let expected = continuationGeneration
        do {
            let result = try await client.home(continuation: token)
            guard expected == continuationGeneration, continuationScope == input.scope else { return [] }
            continuation = result.continuation
            PerfTrace.event("home.innertube.continuation")
            return result.sections
        } catch {
            return []
        }
    }

    func hasContinuation(for sectionID: String) -> Bool {
        shelfContinuations[sectionID] != nil
    }

    func more(sectionID: String, input: HomeDiscoveryInput) async -> [DiscoveryItem] {
        guard continuationScope == input.scope, let token = shelfContinuations[sectionID] else { return [] }
        let expected = continuationGeneration
        do {
            let page = try await client.home(continuation: token)
            guard expected == continuationGeneration, continuationScope == input.scope else { return [] }
            // A shelf continuation is scoped to one renderer. Never append a
            // different shelf's response merely because the server returned a
            // valid page with a changed shape.
            guard let section = page.sections.first(where: { $0.id == sectionID }) else {
                return []
            }
            let items = section.items
            if let next = page.shelfContinuations[sectionID] {
                shelfContinuations[sectionID] = next
            } else {
                shelfContinuations.removeValue(forKey: sectionID)
            }
            PerfTrace.event("home.innertube.continuation")
            return items
        } catch {
            return []
        }
    }

    private func failureCode(_ error: Error) -> HomeFetchFailureCode {
        guard let error = error as? InnertubeError else { return .offline }
        return switch error {
        case .offline: .offline
        case .timedOut, .cancelled: .timedOut
        case .rateLimited: .rateLimited
        case .responseTooLarge: .responseTooLarge
        case .malformedResponse: .malformedResponse
        case .shapeChanged: .shapeChanged
        case .unauthorized: .sessionExpired
        }
    }

    private func failureMessage(_ code: HomeFetchFailureCode) -> String {
        switch code {
        case .offline: tr("YouTube Music is offline.", "YouTube Music 当前离线。")
        case .timedOut: tr("YouTube Music took too long to respond.", "YouTube Music 响应超时。")
        case .rateLimited: tr("YouTube Music temporarily limited requests.", "YouTube Music 暂时限制了请求。")
        case .responseTooLarge: tr("The YouTube Music response exceeded the safety limit.", "YouTube Music 响应超过安全上限。")
        case .shapeChanged: tr("YouTube Music changed its Home response.", "YouTube Music 已更改首页响应结构。")
        default: tr("YouTube Music recommendations are temporarily unavailable.", "YouTube Music 推荐暂时不可用。")
        }
    }
}

/// YouTube Music mode: anonymous Innertube is the baseline and the existing
/// one-shot helper may atomically add the explicitly consented signed-in feed.
@MainActor
final class YouTubeMusicHomeProvider: HomeDiscoveryProvider {
    private let layered: LayeredHomeProvider

    init(anonymous: HomeDiscoveryProvider, authenticated: HomeDiscoveryProvider?) {
        layered = LayeredHomeProvider(
            baseline: anonymous,
            webEnhancement: authenticated)
    }

    var hasWebEnhancement: Bool { layered.hasWebEnhancement }
    func hasContinuation(for sectionID: String) -> Bool {
        layered.hasContinuation(for: sectionID)
    }

    func fetch(for input: HomeDiscoveryInput) async -> HomeFetchResult {
        PerfTrace.event("home.mode.youtubeMusic")
        return await layered.fetch(for: input)
    }

    func more(page: Int, input: HomeDiscoveryInput) async -> [HomeSection] {
        await layered.more(page: page, input: input)
    }

    func more(sectionID: String, input: HomeDiscoveryInput) async -> [DiscoveryItem] {
        await layered.more(sectionID: sectionID, input: input)
    }
}
