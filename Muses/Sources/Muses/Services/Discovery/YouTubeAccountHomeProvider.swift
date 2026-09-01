import Foundation

/// Adds stable, official Data API account content to the public discovery
/// provider. This is the supported fallback when YouTube Music's private Home
/// capability is unavailable; it never pretends OAuth can read the private
/// Music web feed.
@MainActor
final class YouTubeAccountHomeProvider: HomeDiscoveryProvider {
    private let base: HomeDiscoveryProvider
    private let snapshot: () -> YouTubeAccountSnapshot?

    init(base: HomeDiscoveryProvider,
         snapshot: @escaping () -> YouTubeAccountSnapshot?) {
        self.base = base
        self.snapshot = snapshot
    }

    func fetch(for input: HomeDiscoveryInput) async -> HomeFetchResult {
        let baseResult = await base.fetch(for: input)
        var sections = baseResult.baselineSnapshot.sections
        guard case .account(let channelID) = input.scope,
              let account = snapshot(),
              account.channel?.id == channelID,
              !account.likedVideos.isEmpty else {
            return baseResult
        }

        let liked = account.likedVideos.prefix(12).map { video in
            DiscoveryItem.youTube(YouTubeDiscoveryCard(
                id: video.id, title: video.title, uploader: video.channelTitle,
                thumbnailURL: video.thumbnailURL
            ))
        }
        let personalized = HomeSection(
            id: "quick-picks",
            title: tr("Quick picks", "快速精选"),
            subtitle: tr("From your YouTube likes", "来自你的 YouTube 点赞"),
            kind: .quickPicks,
            items: liked,
            status: .loaded,
            source: .officialAccount,
            accountChannelID: channelID
        )
        if let index = sections.firstIndex(where: { $0.id == personalized.id }) {
            sections[index] = personalized
        } else {
            sections.insert(personalized, at: 0)
        }
        let baseline = HomeSnapshot(
            scope: input.scope,
            sections: sections,
            fetchedAt: baseResult.baselineSnapshot.fetchedAt,
            expiresAt: baseResult.baselineSnapshot.expiresAt,
            staleReason: baseResult.baselineSnapshot.staleReason,
            schemaVersion: baseResult.baselineSnapshot.schemaVersion)
        return HomeFetchResult(
            baselineSnapshot: baseline,
            webSnapshot: baseResult.webSnapshot,
            webCapability: baseResult.webCapability,
            failures: baseResult.failures,
            cacheDirectives: baseResult.cacheDirectives)
    }

    func more(page: Int, input: HomeDiscoveryInput) async -> [HomeSection] {
        await base.more(page: page, input: input)
    }
}
