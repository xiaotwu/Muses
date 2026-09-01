import Foundation
import Testing
@testable import Muses

@Suite("Home discovery trust and cache scope")
@MainActor
struct HomeDiscoveryTrustTests {
    @Test("public Home rejects promotional playlists but retains official music")
    func trustGateKeepsOnlyMusicCandidates() {
        let official = YTDlpBridge.YTDlpPlaylistEntry(
            id: "official", title: "Artist — Song (Official Audio)",
            uploader: "Artist", duration: 180)
        let topic = YTDlpBridge.YTDlpPlaylistEntry(
            id: "topic", title: "Song", uploader: "Artist - Topic", duration: 180)
        let promotional = YTDlpBridge.YTDlpPlaylistEntry(
            id: "seo", title: "Top Spotify Hits 2026 | Trending TikTok Playlist",
            uploader: "Playlist Factory", duration: 3600)
        let assertedOfficialReupload = YTDlpBridge.YTDlpPlaylistEntry(
            id: "reupload", title: "Chile One – Destine (Official Audio)",
            uploader: "Unrelated Compilation Channel", duration: 180)
        let titleStuffedWithLabel = YTDlpBridge.YTDlpPlaylistEntry(
            id: "stuffed", title: "Tareef (Official Audio) Artist | Label Records",
            uploader: "Label Records", duration: 180)

        #expect(YouTubeMusicTrust.isTrustedHomeEntry(official))
        #expect(YouTubeMusicTrust.isTrustedHomeEntry(topic))
        #expect(!YouTubeMusicTrust.isTrustedHomeEntry(promotional))
        #expect(!YouTubeMusicTrust.isTrustedHomeEntry(assertedOfficialReupload))
        #expect(!YouTubeMusicTrust.isTrustedHomeEntry(titleStuffedWithLabel))
    }

    @Test("guest and account Home caches are physically isolated")
    func feedCacheDoesNotCrossAccountBoundary() {
        let cache = HomeFeedCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("muses-home-cache-\(UUID().uuidString)", isDirectory: true))
        let guest = input(scope: .guest)
        let account = input(scope: .account(channelID: "UC_account"))
        let section = HomeSection(id: "home", title: "Home", kind: .youTubeCarousel,
                                  items: [], status: .loaded)

        let now = Date()
        let snapshot = HomeSnapshot(
            scope: account.scope, sections: [section], fetchedAt: now,
            expiresAt: now.addingTimeInterval(HomeFeedCache.baselineFreshWindow))
        #expect(cache.set(snapshot, for: account, layer: .baseline))
        #expect(cache.get(for: account, layer: .baseline)?.value.sections.map(\.id) == [section.id])
        #expect(cache.get(for: guest, layer: .baseline) == nil)
    }

    @Test("baseline and Web partitions use independent paths and freshness windows")
    func sourcePartitionsAreIndependent() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muses-home-partitions-\(UUID().uuidString)", isDirectory: true)
        let cache = HomeFeedCache(
            directory: root,
            baselineFreshWindow: 30 * 60,
            webFreshWindow: 15 * 60,
            webStaleLimit: 7 * 24 * 60 * 60)
        let account = input(scope: .account(channelID: "UC_account"))
        let now = Date()
        let fetchedAt = now.addingTimeInterval(-(15 * 60 + 1))
        let baseline = HomeSnapshot(
            scope: account.scope,
            sections: [baselineSection],
            fetchedAt: fetchedAt,
            expiresAt: now.addingTimeInterval(60))
        let web = HomeSnapshot(
            scope: account.scope,
            sections: [HomeSection(
                id: "web", title: "Web", kind: .quickPicks, items: [],
                source: .signedInWeb, accountChannelID: "UC_account")],
            fetchedAt: fetchedAt,
            expiresAt: now.addingTimeInterval(60))

        #expect(cache.set(baseline, for: account, layer: .baseline))
        #expect(cache.set(web, for: account, layer: .webV1))
        let cachedBaseline = cache.get(for: account, layer: .baseline, now: now)
        let cachedWeb = cache.get(for: account, layer: .webV1, now: now)

        #expect(cachedBaseline != nil)
        #expect(cachedWeb != nil)
        #expect(cache.isFresh(cachedBaseline!, layer: .baseline, now: now))
        #expect(!cache.isFresh(cachedWeb!, layer: .webV1, now: now))
        #expect(cache.directoryURL(for: account.scope, layer: .baseline).path
            .hasSuffix("account-UC_account/baseline"))
        #expect(cache.directoryURL(for: account.scope, layer: .webV1).path
            .hasSuffix("account-UC_account/web-v1"))
    }

    @Test("legacy combined JSON is invalidated without touching partition directories")
    func legacyCombinedCacheIsInvalidated() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muses-home-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = root.appendingPathComponent("legacy.json")
        let partition = root.appendingPathComponent("account-UC_one", isDirectory: true)
        try Data("legacy".utf8).write(to: legacy)
        try FileManager.default.createDirectory(at: partition, withIntermediateDirectories: true)

        _ = HomeFeedCache(directory: root)

        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: partition.path))
    }

    @Test("Web snapshots older than seven days are not presented")
    func webStaleLimitIsSevenDays() {
        let cache = HomeFeedCache(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("muses-home-stale-\(UUID().uuidString)", isDirectory: true))
        let account = input(scope: .account(channelID: "UC_account"))
        let now = Date()
        let fetchedAt = now.addingTimeInterval(-(HomeFeedCache.webStaleLimit + 1))
        let web = HomeSnapshot(
            scope: account.scope,
            sections: [HomeSection(
                id: "web", title: "Web", kind: .quickPicks, items: [],
                source: .signedInWeb, accountChannelID: "UC_account")],
            fetchedAt: fetchedAt,
            expiresAt: fetchedAt.addingTimeInterval(HomeFeedCache.webFreshWindow))

        #expect(cache.set(web, for: account, layer: .webV1))
        #expect(cache.get(for: account, layer: .webV1, now: now) == nil)
    }

    @Test("Home snapshot manifest rejects cross-account section metadata")
    func snapshotManifestRejectsCrossAccountContent() {
        let now = Date()
        let snapshot = HomeSnapshot(
            scope: .account(channelID: "UC_one"),
            sections: [HomeSection(
                id: "wrong", title: "Wrong", kind: .youTubeCarousel,
                items: [], source: .signedInWeb,
                accountChannelID: "UC_two")],
            fetchedAt: now, expiresAt: now.addingTimeInterval(60))

        #expect(!snapshot.belongs(to: .account(channelID: "UC_one")))
        #expect(!snapshot.belongs(to: .account(channelID: "UC_two")))
        #expect(!snapshot.belongs(to: .guest))
    }

    @Test("blank account ids use the guest scope")
    func blankAccountIsGuest() {
        #expect(HomeFeedScope(accountChannelID: "  ") == .guest)
        #expect(HomeFeedScope(accountChannelID: "UC_one") == .account(channelID: "UC_one"))
    }

    @Test("older cached sections decode as public discovery")
    func legacySectionDecodeDefaultsSource() throws {
        let original = HomeSection(id: "legacy", title: "Legacy", kind: .youTubeCarousel,
                                   items: [], status: .loaded)
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "source")
        object.removeValue(forKey: "schemaVersion")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(HomeSection.self, from: legacy)

        #expect(decoded.source == .publicDiscovery)
        #expect(decoded.schemaVersion == 1)
    }

    @Test("cache presentation keeps the actual upstream source")
    func cachedSectionKeepsOrigin() {
        let live = HomeSection(id: "account", title: "Account", kind: .quickPicks,
                               items: [], source: .officialAccount,
                               accountChannelID: "UC_one")
        let cached = live.presentedFromCache(staleReason: "offline")

        #expect(cached.source == .cached)
        #expect(cached.cachedOrigin == .officialAccount)
        #expect(cached.accountChannelID == "UC_one")
        #expect(cached.staleReason == "offline")
    }

    @Test("official account content never crosses guest or account scope")
    func accountProviderRequiresExactScope() async {
        let baseline = StubHomeProvider(sections: [baselineSection])
        let account = snapshot(channelID: "UC_one")
        let provider = YouTubeAccountHomeProvider(base: baseline, snapshot: { account })

        let guest = await provider.fetch(for: input(scope: .guest)).baselineSnapshot.sections
        let other = await provider.fetch(
            for: input(scope: .account(channelID: "UC_two"))).baselineSnapshot.sections
        let matching = await provider.fetch(
            for: input(scope: .account(channelID: "UC_one"))).baselineSnapshot.sections

        #expect(guest.allSatisfy { $0.source != .officialAccount })
        #expect(other.allSatisfy { $0.source != .officialAccount })
        #expect(matching.first?.source == .officialAccount)
        #expect(matching.first?.accountChannelID == "UC_one")
    }

    @Test("Web enhancement failure and account mismatch preserve baseline")
    func layeredProviderRejectsUnsafeEnhancement() async {
        let baseline = StubHomeProvider(sections: [baselineSection])
        let wrongAccountWeb = StubHomeProvider(webSections: [
            HomeSection(id: "web", title: "Web", kind: .youTubeCarousel,
                        items: [], source: .signedInWeb,
                        accountChannelID: "UC_other")
        ])
        let mismatched = LayeredHomeProvider(
            baseline: baseline, webEnhancement: wrongAccountWeb)
        let mismatchResult = await mismatched.fetch(
            for: input(scope: .account(channelID: "UC_one")))
        #expect(mismatchResult.baselineSnapshot.sections.map(\.id) == ["baseline"])
        #expect(mismatchResult.webSnapshot == nil)
        if case .rejected = mismatchResult.webCapability {} else {
            Issue.record("Expected the mismatched Web payload to be rejected")
        }

        let failedWeb = StubHomeProvider(
            webFailure: HomeFetchFailure(
                layer: .web, code: .sessionExpired, message: "session expired"))
        let failed = LayeredHomeProvider(baseline: baseline, webEnhancement: failedWeb)
        let failedResult = await failed.fetch(
            for: input(scope: .account(channelID: "UC_one")))
        #expect(failedResult.baselineSnapshot.sections.map(\.id) == ["baseline"])
        #expect(failedResult.webSnapshot == nil)
        #expect(failedResult.webCapability == .unavailable(reason: "session expired"))
        #expect(!failedResult.cacheDirectives.storeWeb)
    }

    @Test("valid Web sections enhance and supersede matching baseline slots")
    func layeredProviderAcceptsExactAccount() async {
        let baseline = StubHomeProvider(sections: [
            baselineSection,
            HomeSection(id: "shared", title: "Baseline shared", kind: .youTubeCarousel,
                        items: [], source: .publicDiscovery)
        ])
        let web = StubHomeProvider(webSections: [
            HomeSection(id: "shared", title: "Personalized shared", kind: .youTubeCarousel,
                        items: [], source: .signedInWeb,
                        accountChannelID: "UC_one", schemaVersion: 2)
        ])
        let provider = LayeredHomeProvider(baseline: baseline, webEnhancement: web)
        let result = await provider.fetch(
            for: input(scope: .account(channelID: "UC_one")))

        #expect(result.webSnapshot?.sections.map(\.id) == ["shared"])
        #expect(result.baselineSnapshot.sections.map(\.id) == ["baseline", "shared"])
        #expect(result.webCapability == .available(accountChannelID: "UC_one"))
        #expect(result.cacheDirectives.storeWeb)
    }

    @Test("a Web failure keeps and presents the same-account last success")
    func failedWebRefreshPreservesLastSuccess() async throws {
        let provider = SuccessfulThenFailedWebProvider()
        let cache = temporaryCache()
        var channelID: String? = "UC_one"
        let service = HomeDiscoveryService(
            provider: provider,
            cache: cache,
            library: LibraryService(modelContainer: try makeModelContainer(inMemory: true)),
            enabledProvider: { true },
            accountChannelIDProvider: { channelID })

        service.load()
        for _ in 0..<50 where provider.fetchCount < 1 || service.isRefreshing {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(service.sections.first?.source == .signedInWeb)

        service.reload()
        for _ in 0..<50 where provider.fetchCount < 2 || service.isRefreshing {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(service.sections.first?.source == .cached)
        #expect(service.sections.first?.cachedOrigin == .signedInWeb)
        #expect(service.sections.first?.id == "web-success")
        #expect(cache.get(
            for: service.buildInput(),
            layer: .webV1)?.value.sections.first?.id == "web-success")
        if case .saved(let accountID, let stale, _) = service.webCapability {
            #expect(accountID == "UC_one")
            #expect(stale)
        } else {
            Issue.record("Expected the last successful Web snapshot to remain visible")
        }
        channelID = nil
    }

    @Test("async reload preserves the explicit account scope")
    func asyncReloadUsesAccountScope() async throws {
        let provider = ScopeRecordingHomeProvider()
        var channelID: String? = "UC_one"
        let service = HomeDiscoveryService(
            provider: provider,
            cache: temporaryCache(),
            library: LibraryService(modelContainer: try makeModelContainer(inMemory: true)),
            enabledProvider: { true },
            accountChannelIDProvider: { channelID })

        service.reload()
        for _ in 0..<50 where provider.inputs.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(provider.inputs.last?.scope == .account(channelID: "UC_one"))
        channelID = nil
    }

    @Test("logout and A-to-B switch discard a cancelled account result that arrives late")
    func scopeSwitchRejectsLateResult() async throws {
        let provider = ScopeRecordingHomeProvider(delayedScope: .account(channelID: "UC_A"))
        var channelID: String? = "UC_A"
        let service = HomeDiscoveryService(
            provider: provider,
            cache: temporaryCache(),
            library: LibraryService(modelContainer: try makeModelContainer(inMemory: true)),
            enabledProvider: { true },
            accountChannelIDProvider: { channelID })

        service.load()
        channelID = "UC_B"
        service.accountScopeDidChange()
        for _ in 0..<50 where service.sections.first?.accountChannelID != "UC_B" {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(220))

        #expect(service.sections.map(\.accountChannelID) == ["UC_B"])
        #expect(service.activeScope == .account(channelID: "UC_B"))

        channelID = nil
        service.accountScopeDidChange()
        for _ in 0..<50 where service.sections.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(service.activeScope == .guest)
        #expect(service.sections.allSatisfy { $0.accountChannelID == nil })
    }

    @Test("disabled Web Home neither presents its saved partition nor refreshes it")
    func disabledWebDoesNotAppear() throws {
        let cache = temporaryCache()
        let provider = StubHomeProvider(sections: [baselineSection])
        let service = HomeDiscoveryService(
            provider: provider,
            cache: cache,
            library: LibraryService(modelContainer: try makeModelContainer(inMemory: true)),
            enabledProvider: { true },
            accountChannelIDProvider: { "UC_one" })
        let accountInput = service.buildInput()
        let now = Date()
        let baseline = HomeSnapshot(
            scope: accountInput.scope,
            sections: [baselineSection],
            fetchedAt: now,
            expiresAt: now.addingTimeInterval(HomeFeedCache.baselineFreshWindow))
        let web = HomeSnapshot(
            scope: accountInput.scope,
            sections: [HomeSection(
                id: "saved-web", title: "Saved Web", kind: .quickPicks,
                items: [.youTube(YouTubeDiscoveryCard(id: "web-video", title: "Web"))],
                source: .signedInWeb, accountChannelID: "UC_one")],
            fetchedAt: now,
            expiresAt: now.addingTimeInterval(HomeFeedCache.webFreshWindow))
        #expect(cache.set(baseline, for: accountInput, layer: .baseline))
        #expect(cache.set(web, for: accountInput, layer: .webV1))

        service.load()

        #expect(service.sections.map(\.id) == ["baseline"])
        #expect(service.webCapability == .notConfigured)
    }

    @Test("live Web media wins over duplicate baseline media")
    func liveWebDeduplicatesBaseline() async throws {
        let provider = DeduplicatingHomeProvider()
        let service = HomeDiscoveryService(
            provider: provider,
            cache: temporaryCache(),
            library: LibraryService(modelContainer: try makeModelContainer(inMemory: true)),
            enabledProvider: { true },
            accountChannelIDProvider: { "UC_one" })

        service.load()
        for _ in 0..<50 where service.isRefreshing {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(service.sections.map(\.id) == ["web", "baseline"])
        #expect(service.sections[0].items.map(\.homeMediaIdentity) == ["video:duplicate"])
        #expect(service.sections[1].items.map(\.homeMediaIdentity) == ["video:baseline-only"])
    }

    private func input(scope: HomeFeedScope) -> HomeDiscoveryInput {
        HomeDiscoveryInput(topArtistNames: [], recentlyPlayedArtistNames: [],
                           likedArtistNames: [], timeBand: .morning, hour: 8,
                           scope: scope)
    }

    private var baselineSection: HomeSection {
        HomeSection(id: "baseline", title: "Baseline", kind: .youTubeCarousel,
                    items: [], source: .publicDiscovery)
    }

    private func snapshot(channelID: String) -> YouTubeAccountSnapshot {
        YouTubeAccountSnapshot(
            channel: YouTubeChannel(id: channelID, title: "Account", thumbnailURL: nil),
            playlists: [], subscriptions: [],
            likedVideos: [YouTubeVideo(id: "liked", title: "Liked",
                                       channelTitle: "Artist", thumbnailURL: nil)])
    }

    private func temporaryCache() -> HomeFeedCache {
        HomeFeedCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("muses-home-service-\(UUID().uuidString)", isDirectory: true))
    }
}

@MainActor
private final class StubHomeProvider: HomeDiscoveryProvider {
    let result: [HomeSection]
    let isWeb: Bool
    let webFailure: HomeFetchFailure?
    var hasWebEnhancement: Bool { isWeb }

    init(sections: [HomeSection]) {
        self.result = sections
        self.isWeb = false
        self.webFailure = nil
    }

    init(webSections: [HomeSection]) {
        self.result = webSections
        self.isWeb = true
        self.webFailure = nil
    }

    init(webFailure: HomeFetchFailure) {
        self.result = []
        self.isWeb = true
        self.webFailure = webFailure
    }

    func fetch(for input: HomeDiscoveryInput) async -> HomeFetchResult {
        guard isWeb else {
            return .baseline(scope: input.scope, sections: result)
        }
        let baseline = HomeFetchResult.baseline(scope: input.scope, sections: [])
            .baselineSnapshot
        if let webFailure {
            return HomeFetchResult(
                baselineSnapshot: baseline,
                webSnapshot: nil,
                webCapability: .unavailable(reason: webFailure.message),
                failures: [webFailure],
                cacheDirectives: .preserveAll)
        }
        let now = Date()
        let webSnapshot = HomeSnapshot(
            scope: input.scope,
            sections: result,
            fetchedAt: now,
            expiresAt: now.addingTimeInterval(HomeFeedCache.webFreshWindow))
        return HomeFetchResult(
            baselineSnapshot: baseline,
            webSnapshot: webSnapshot,
            webCapability: .available(accountChannelID: input.scope.accountChannelID),
            failures: [],
            cacheDirectives: HomeCacheDirectives(storeBaseline: false, storeWeb: true))
    }
}

@MainActor
private final class ScopeRecordingHomeProvider: HomeDiscoveryProvider {
    private(set) var inputs: [HomeDiscoveryInput] = []
    let delayedScope: HomeFeedScope?

    init(delayedScope: HomeFeedScope? = nil) {
        self.delayedScope = delayedScope
    }

    func fetch(for input: HomeDiscoveryInput) async -> HomeFetchResult {
        inputs.append(input)
        if input.scope == delayedScope {
            // Deliberately ignore cancellation to emulate an uncooperative
            // transport whose old account payload arrives after a switch.
            await Task.detached {
                try? await Task.sleep(for: .milliseconds(150))
            }.value
        }
        let accountID: String?
        switch input.scope {
        case .guest: accountID = nil
        case .account(let value): accountID = value
        }
        return .baseline(scope: input.scope, sections: [HomeSection(
            id: "scope", title: "Scope", kind: .youTubeCarousel, items: [],
            source: accountID == nil ? .publicDiscovery : .officialAccount,
            accountChannelID: accountID)])
    }
}

@MainActor
private final class SuccessfulThenFailedWebProvider: HomeDiscoveryProvider {
    private(set) var fetchCount = 0
    let hasWebEnhancement = true

    func fetch(for input: HomeDiscoveryInput) async -> HomeFetchResult {
        fetchCount += 1
        let baseline = HomeFetchResult.baseline(
            scope: input.scope,
            sections: [HomeSection(
                id: "baseline", title: "Baseline", kind: .youTubeCarousel,
                items: [], source: .publicDiscovery)])
        guard fetchCount == 1,
              case .account(let channelID) = input.scope else {
            return HomeFetchResult(
                baselineSnapshot: baseline.baselineSnapshot,
                webSnapshot: nil,
                webCapability: .unavailable(reason: "offline"),
                failures: [HomeFetchFailure(
                    layer: .web, code: .offline, message: "offline")],
                cacheDirectives: HomeCacheDirectives(
                    storeBaseline: true, storeWeb: false))
        }
        let now = Date()
        let web = HomeSnapshot(
            scope: input.scope,
            sections: [HomeSection(
                id: "web-success", title: "Web", kind: .quickPicks,
                items: [], source: .signedInWeb, accountChannelID: channelID)],
            fetchedAt: now,
            expiresAt: now.addingTimeInterval(HomeFeedCache.webFreshWindow))
        return HomeFetchResult(
            baselineSnapshot: baseline.baselineSnapshot,
            webSnapshot: web,
            webCapability: .available(accountChannelID: channelID),
            failures: [],
            cacheDirectives: HomeCacheDirectives(storeBaseline: true, storeWeb: true))
    }
}

@MainActor
private final class DeduplicatingHomeProvider: HomeDiscoveryProvider {
    let hasWebEnhancement = true

    func fetch(for input: HomeDiscoveryInput) async -> HomeFetchResult {
        let now = Date()
        let baseline = HomeSnapshot(
            scope: input.scope,
            sections: [HomeSection(
                id: "baseline", title: "Baseline", kind: .youTubeCarousel,
                items: [
                    .youTube(YouTubeDiscoveryCard(id: "duplicate", title: "Duplicate")),
                    .youTube(YouTubeDiscoveryCard(id: "baseline-only", title: "Only"))
                ], source: .publicDiscovery)],
            fetchedAt: now,
            expiresAt: now.addingTimeInterval(HomeFeedCache.baselineFreshWindow))
        let web = HomeSnapshot(
            scope: input.scope,
            sections: [HomeSection(
                id: "web", title: "Web", kind: .quickPicks,
                items: [.youTube(YouTubeDiscoveryCard(
                    id: "video:duplicate", title: "Duplicate Web",
                    browseEndpoint: nil,
                    playEndpoint: HomeCardEndpoint(kind: .video, identifier: "duplicate"),
                    availability: .available))],
                source: .signedInWeb,
                accountChannelID: input.scope.accountChannelID)],
            fetchedAt: now,
            expiresAt: now.addingTimeInterval(HomeFeedCache.webFreshWindow))
        return HomeFetchResult(
            baselineSnapshot: baseline,
            webSnapshot: web,
            webCapability: .available(accountChannelID: input.scope.accountChannelID),
            failures: [],
            cacheDirectives: HomeCacheDirectives(storeBaseline: true, storeWeb: true))
    }
}

private extension HomeFeedScope {
    var accountChannelID: String {
        if case .account(let channelID) = self { return channelID }
        return ""
    }
}
