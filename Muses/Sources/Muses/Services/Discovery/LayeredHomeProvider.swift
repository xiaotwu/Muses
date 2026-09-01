import Foundation

/// Composes the stable baseline and optional signed-in Web layer while keeping
/// their snapshots and cache directives physically independent.
@MainActor
final class LayeredHomeProvider: HomeDiscoveryProvider {
    private let baseline: HomeDiscoveryProvider
    private let webEnhancement: HomeDiscoveryProvider?

    var hasWebEnhancement: Bool { webEnhancement?.hasWebEnhancement == true }

    init(baseline: HomeDiscoveryProvider,
         webEnhancement: HomeDiscoveryProvider? = nil) {
        self.baseline = baseline
        self.webEnhancement = webEnhancement
    }

    func fetch(for input: HomeDiscoveryInput) async -> HomeFetchResult {
        let baselineResult = await baseline.fetch(for: input)
        guard case .account(let channelID) = input.scope else {
            return result(
                baseline: baselineResult,
                webSnapshot: nil,
                capability: hasWebEnhancement ? .signedOut : .notConfigured,
                webFailures: [],
                storeWeb: false)
        }
        guard let webEnhancement, webEnhancement.hasWebEnhancement else {
            return result(
                baseline: baselineResult,
                webSnapshot: nil,
                capability: .notConfigured,
                webFailures: [],
                storeWeb: false)
        }

        let webResult = await webEnhancement.fetch(for: input)
        let webFailures = webResult.failures.filter { $0.layer == .web }
        guard webFailures.isEmpty else {
            return result(
                baseline: baselineResult,
                webSnapshot: nil,
                capability: webResult.webCapability,
                webFailures: webFailures,
                storeWeb: false)
        }

        guard let webSnapshot = webResult.webSnapshot else {
            let capability: HomeWebCapability
            switch webResult.webCapability {
            case .notConfigured, .available:
                capability = .unavailable(reason: nil)
            default:
                capability = webResult.webCapability
            }
            return result(
                baseline: baselineResult,
                webSnapshot: nil,
                capability: capability,
                webFailures: [],
                storeWeb: false)
        }

        guard webSnapshot.belongs(to: input.scope),
              !webSnapshot.sections.isEmpty,
              webSnapshot.sections.allSatisfy({ section in
                  section.source == .signedInWeb
                      && section.accountChannelID == channelID
                      && section.schemaVersion > 0
                      && section.status == .loaded
              }) else {
            let message = tr(
                "Personalized Home data did not match the active account or schema.",
                "个性化首页数据与当前账号或架构不匹配。")
            return result(
                baseline: baselineResult,
                webSnapshot: nil,
                capability: .rejected(reason: message),
                webFailures: [HomeFetchFailure(
                    layer: .web,
                    code: .shapeChanged,
                    message: message)],
                storeWeb: false)
        }

        return result(
            baseline: baselineResult,
            webSnapshot: webSnapshot,
            capability: .available(accountChannelID: channelID),
            webFailures: [],
            storeWeb: webResult.cacheDirectives.storeWeb)
    }

    func more(page: Int, input: HomeDiscoveryInput) async -> [HomeSection] {
        await baseline.more(page: page, input: input)
    }

    private func result(
        baseline: HomeFetchResult,
        webSnapshot: HomeSnapshot?,
        capability: HomeWebCapability,
        webFailures: [HomeFetchFailure],
        storeWeb: Bool
    ) -> HomeFetchResult {
        HomeFetchResult(
            baselineSnapshot: baseline.baselineSnapshot,
            webSnapshot: webSnapshot,
            webCapability: capability,
            failures: baseline.failures + webFailures,
            cacheDirectives: HomeCacheDirectives(
                storeBaseline: baseline.cacheDirectives.storeBaseline,
                storeWeb: storeWeb))
    }
}
