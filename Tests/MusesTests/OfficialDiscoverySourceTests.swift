import Foundation
import Testing
@testable import Muses

@Suite("Official discovery sources")
@MainActor
struct OfficialDiscoverySourceTests {
    private var input: HomeDiscoveryInput {
        .init(topArtistNames: ["Favorite"], recentlyPlayedArtistNames: ["Favorite"],
              likedArtistNames: ["Favorite"], timeBand: .morning, hour: 9, scope: .guest)
    }

    @Test("Catalog failure stays failed and never produces invented history or extra pages")
    func failureHasNoSearchFallback() async {
        let provider = YTDlpDiscoveryProvider { _ in throw URLError(.notConnectedToInternet) }
        let result = await provider.fetch(for: input)
        #expect(result.baselineSnapshot.sections.count == 2)
        #expect(result.baselineSnapshot.sections.allSatisfy {
            if case .failed = $0.status { return $0.items.isEmpty }
            return false
        })
        #expect(!result.baselineSnapshot.sections.contains { $0.id == "listen-again" || $0.id == "trending" })
        #expect(await provider.more(page: 1, input: input).isEmpty)
    }

    @Test("Unverified Music browse extraction cannot masquerade as an official catalog")
    func rejectsUnverifiedBrowseExtraction() async {
        var requests = 0
        let provider = YTDlpDiscoveryProvider { _ in
            requests += 1
            return [.init(id: "lY5V4hSLWY8", title: "Unrelated upload")]
        }
        let result = await provider.fetch(for: input)
        #expect(requests == 0)
        #expect(result.baselineSnapshot.sections.allSatisfy { $0.items.isEmpty })
        #expect(!result.failures.isEmpty)
    }
}
