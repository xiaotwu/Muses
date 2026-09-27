import Foundation

@MainActor
final class ModeSwitchingHomeDiscoveryProvider: HomeDiscoveryProvider {
    private let modeProvider: () -> HomeRecommendationMode
    private let muses: HomeDiscoveryProvider
    private let youtubeMusic: HomeDiscoveryProvider

    init(
        modeProvider: @escaping () -> HomeRecommendationMode,
        muses: HomeDiscoveryProvider,
        youtubeMusic: HomeDiscoveryProvider
    ) {
        self.modeProvider = modeProvider
        self.muses = muses
        self.youtubeMusic = youtubeMusic
    }

    private var active: HomeDiscoveryProvider {
        switch modeProvider() {
        case .muses: muses
        case .youtubeMusic: youtubeMusic
        }
    }

    var hasWebEnhancement: Bool { active.hasWebEnhancement }
    var hasGlobalContinuation: Bool { active.hasGlobalContinuation }
    var needsLiveRefreshForContinuations: Bool {
        active.needsLiveRefreshForContinuations
    }
    func resetContinuations() {
        muses.resetContinuations()
        youtubeMusic.resetContinuations()
    }
    func hasContinuation(for sectionID: String) -> Bool {
        active.hasContinuation(for: sectionID)
    }

    func fetch(for input: HomeDiscoveryInput) async -> HomeFetchResult {
        await active.fetch(for: input)
    }

    func more(page: Int, input: HomeDiscoveryInput) async -> [HomeSection] {
        await active.more(page: page, input: input)
    }

    func more(sectionID: String, input: HomeDiscoveryInput) async -> [DiscoveryItem] {
        await active.more(sectionID: sectionID, input: input)
    }
}
