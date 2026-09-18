import Foundation

@MainActor
final class MusesHomeProvider: HomeDiscoveryProvider {
    private let library: LibraryService
    private let engine: LocalRecommendationEngine

    init(library: LibraryService, engine: LocalRecommendationEngine = .init()) {
        self.library = library
        self.engine = engine
    }

    func fetch(for input: HomeDiscoveryInput) async -> HomeFetchResult {
        let now = Date()
        let tracks = library.allTracks().compactMap { track -> TrackRecommendationSnapshot? in
            guard !track.youTubeId.isEmpty else { return nil }
            return TrackRecommendationSnapshot(
                track: TrackSnapshot(from: track),
                artistCatalogID: track.artistCatalogID,
                playCount: track.playCount,
                isFavorite: track.liked,
                addedAt: track.addedAt,
                lastPlayedAt: track.lastPlayedAt)
        }
        let localInput = LocalRecommendationInput(
            tracks: tracks,
            currentHour: input.hour,
            timeBand: input.timeBand,
            now: now)
        let localEngine = engine
        let sections = await Task.detached(priority: .utility) {
            localEngine.plan(for: localInput)
        }.value
        PerfTrace.event("home.mode.muses")
        return .baseline(scope: input.scope, sections: sections, fetchedAt: now)
    }
}
