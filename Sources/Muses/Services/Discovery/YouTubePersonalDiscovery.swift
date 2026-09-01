import Foundation

/// New-tab personalization from YouTube Data API likes plus yt-dlp radio mixes.
@MainActor
enum YouTubePersonalDiscovery {
    static func likedSection(videos: [YouTubeVideo]) -> HomeSection? {
        guard !videos.isEmpty else { return nil }
        let items = videos.prefix(20).map {
            DiscoveryItem.youTube(YouTubeDiscoveryCard(
                id: $0.id,
                title: $0.title,
                uploader: $0.channelTitle,
                thumbnailURL: $0.thumbnailURL))
        }
        return HomeSection(
            id: "yt-liked",
            title: tr("Liked on YouTube", "YouTube 喜欢"),
            subtitle: tr("From your account", "来自你的账号"),
            kind: .youTubeCarousel,
            items: Array(items),
            status: .loaded)
    }

    static func mixSection(title: String, entries: [YTDlpBridge.YTDlpPlaylistEntry]) -> HomeSection? {
        guard !entries.isEmpty else { return nil }
        let items = entries.prefix(12).map {
            DiscoveryItem.youTube(YouTubeDiscoveryCard(entry: $0))
        }
        return HomeSection(
            id: "yt-mix-\(title)",
            title: tr("Because you liked \(title)", "因为你喜欢 \(title)"),
            subtitle: tr("Mix from YouTube Music", "YouTube Music 电台"),
            kind: .youTubeCarousel,
            items: Array(items),
            status: .loaded)
    }

    static func subscriptionsSection(title: String,
                                     entries: [YTDlpBridge.YTDlpPlaylistEntry]) -> HomeSection? {
        guard !entries.isEmpty else { return nil }
        let items = entries.prefix(12).map {
            DiscoveryItem.youTube(YouTubeDiscoveryCard(entry: $0))
        }
        return HomeSection(
            id: "yt-subs",
            title: tr("From \(title)", "来自 \(title)"),
            subtitle: tr("From your subscriptions", "来自你的订阅"),
            kind: .youTubeCarousel,
            items: Array(items),
            status: .loaded)
    }

    static func sections(
        liked: [YouTubeVideo],
        subscriptionTitles: [String] = [],
        fetchMix: (String) async throws -> [YTDlpBridge.YTDlpPlaylistEntry],
        search: ((String) async throws -> [YTDlpBridge.YTDlpPlaylistEntry])? = nil
    ) async -> [HomeSection] {
        var out: [HomeSection] = []
        if let likedSection = likedSection(videos: liked) {
            out.append(likedSection)
        }
        if let seed = liked.first {
            if let mix = try? await fetchMix(YouTubeMusicCatalog.mix(videoId: seed.id)),
               let section = mixSection(title: seed.title, entries: mix) {
                out.append(section)
            }
        }
        if let channel = subscriptionTitles.first, let search {
            if let entries = try? await search("\(channel) official music"),
               let section = subscriptionsSection(title: channel, entries: entries) {
                out.append(section)
            }
        }
        return out
    }
}
