import Foundation

/// A Home feed is either public guest discovery or owned by one concrete
/// YouTube channel. The scope is deliberately non-optional so callers cannot
/// accidentally fall back to the guest cache while refreshing an account.
enum HomeFeedScope: Codable, Hashable, Sendable {
    case guest
    case account(channelID: String)

    init(accountChannelID: String?) {
        let normalized = accountChannelID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty else {
            self = .guest
            return
        }
        self = .account(channelID: normalized)
    }

    var cacheNamespace: String {
        switch self {
        case .guest:
            return "guest"
        case .account(let channelID):
            let safeID = channelID.unicodeScalars.map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar) || scalar.value == 45 || scalar.value == 95
                    ? Character(String(scalar)) : "_"
            }
            return "account-\(String(safeID))"
        }
    }
}

/// Home discovery input: carries the lightweight signals a provider needs to build
/// sections.
///
/// All fields are `Sendable` values, safe to pass across actors. The input contains only
/// **light** history-based ordering signals (top/recent/liked artist names); strong
/// personalization lives in New.
struct HomeDiscoveryInput: Sendable, Equatable {
    /// Artist names the user listens to most (descending by play count, up to 5).
    let topArtistNames: [String]
    /// Artist names seen in recently played tracks (deduplicated, up to 5).
    let recentlyPlayedArtistNames: [String]
    /// Artist names from liked tracks (deduplicated, up to 5).
    let likedArtistNames: [String]
    /// Current local time band (used for time-themed sections, e.g. morning/lateNight).
    let timeBand: ListeningContext.TimeBand
    /// Current hour (0-23), letting providers refine themes.
    let hour: Int
    /// Recently played YouTube video ids, used as mix seeds (`list=RD{id}`).
    let seedVideoIds: [String]
    /// Cache and refresh ownership. This is never optional: a signed-out load
    /// cannot accidentally reuse another account's saved Home response.
    let scope: HomeFeedScope

    init(topArtistNames: [String],
         recentlyPlayedArtistNames: [String],
         likedArtistNames: [String],
         timeBand: ListeningContext.TimeBand,
         hour: Int,
         seedVideoIds: [String] = [],
         scope: HomeFeedScope) {
        self.topArtistNames = topArtistNames
        self.recentlyPlayedArtistNames = recentlyPlayedArtistNames
        self.likedArtistNames = likedArtistNames
        self.timeBand = timeBand
        self.hour = hour
        self.seedVideoIds = seedVideoIds
        self.scope = scope
    }

    static func == (lhs: HomeDiscoveryInput, rhs: HomeDiscoveryInput) -> Bool {
        lhs.topArtistNames == rhs.topArtistNames
            && lhs.recentlyPlayedArtistNames == rhs.recentlyPlayedArtistNames
            && lhs.likedArtistNames == rhs.likedArtistNames
            && lhs.timeBand == rhs.timeBand
            && lhs.hour == rhs.hour
            && lhs.seedVideoIds == rhs.seedVideoIds
            && lhs.scope == rhs.scope
    }

    /// Merges YouTube account personalization signals (background refresh path): folds the
    /// account's liked/subscribed artist names into the local seeds (deduplicated, order
    /// preserved, capped at 5) as extra discovery seeds. `timeBand`/`hour` are unchanged.
    func enriched(with signals: PersonalizationSignals) -> HomeDiscoveryInput {
        func merge(_ local: [String], _ extra: [String]) -> [String] {
            var seen = Set<String>()
            var out: [String] = []
            for name in local + extra {
                let key = name.lowercased()
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                out.append(name)
                if out.count >= 5 { break }
            }
            return out
        }
        return HomeDiscoveryInput(
            topArtistNames: merge(topArtistNames, signals.likedArtistNames),
            recentlyPlayedArtistNames: recentlyPlayedArtistNames,
            likedArtistNames: merge(likedArtistNames, signals.subscribedChannelNames),
            timeBand: timeBand,
            hour: hour,
            seedVideoIds: seedVideoIds,
            scope: scope)
    }
}

enum HomeFetchFailureCode: String, Codable, Sendable, Equatable {
    case disabled
    case oauthRequired
    case cookieSourceUnavailable
    case sessionExpired
    case consentOrCaptchaRequired
    case identityUnavailable
    case accountMismatch
    case shapeChanged
    case rateLimited
    case offline
    case timedOut
    case helperCrashed
    case protocolMismatch
    case responseTooLarge
    case malformedResponse
    case baselineUnavailable
}

struct HomeFetchFailure: Codable, Sendable, Equatable {
    enum Layer: String, Codable, Sendable {
        case baseline
        case web
    }

    let layer: Layer
    let code: HomeFetchFailureCode
    let message: String?
}

/// Cache writes are part of the fetch value so a caller never infers them from
/// a mutable capability observed after an await. In particular, a failed Web
/// fetch always preserves the last successful Web partition.
struct HomeCacheDirectives: Sendable, Equatable {
    let storeBaseline: Bool
    let storeWeb: Bool

    static let preserveAll = HomeCacheDirectives(storeBaseline: false, storeWeb: false)
}

/// One immutable outcome for one Home refresh. Baseline and Web data remain
/// separate until presentation so a baseline success can never overwrite a
/// same-account Web snapshot after the enhancement fails.
struct HomeFetchResult: Sendable {
    let baselineSnapshot: HomeSnapshot
    let webSnapshot: HomeSnapshot?
    let webCapability: HomeWebCapability
    let failures: [HomeFetchFailure]
    let cacheDirectives: HomeCacheDirectives

    static func baseline(
        scope: HomeFeedScope,
        sections: [HomeSection],
        fetchedAt: Date = .init(),
        failures: [HomeFetchFailure] = []
    ) -> HomeFetchResult {
        let hasSectionFailure = sections.contains { section in
            if case .failed = section.status { return true }
            return false
        }
        return HomeFetchResult(
            baselineSnapshot: HomeSnapshot(
                scope: scope,
                sections: sections,
                fetchedAt: fetchedAt,
                expiresAt: fetchedAt.addingTimeInterval(HomeFeedCache.baselineFreshWindow)),
            webSnapshot: nil,
            webCapability: .notConfigured,
            failures: failures,
            cacheDirectives: HomeCacheDirectives(
                storeBaseline: !hasSectionFailure && failures.isEmpty,
                storeWeb: false))
    }
}

/// Home discovery provider. A refresh returns content, capability, failures,
/// and cache policy atomically. `hasWebEnhancement` is immutable configuration,
/// not mutable outcome state, and is used only to decide whether a fresh Web
/// partition is required before skipping refresh.
@MainActor
protocol HomeDiscoveryProvider: AnyObject {
    var hasWebEnhancement: Bool { get }
    func fetch(for input: HomeDiscoveryInput) async -> HomeFetchResult
    func more(page: Int, input: HomeDiscoveryInput) async -> [HomeSection]
}

extension HomeDiscoveryProvider {
    var hasWebEnhancement: Bool { false }
    func more(page: Int, input: HomeDiscoveryInput) async -> [HomeSection] { [] }
}

/// Observable truth for the optional Web-session layer. It intentionally does
/// not collapse into a Boolean: signed-out, disabled, rejected, and failed are
/// different product states with different recovery paths.
enum HomeWebCapability: Sendable, Equatable {
    case notConfigured
    case signedOut
    case available(accountChannelID: String)
    case saved(accountChannelID: String, stale: Bool, reason: String?)
    case unavailable(reason: String?)
    case rejected(reason: String)

    var isActive: Bool {
        if case .available = self { return true }
        return false
    }
}
