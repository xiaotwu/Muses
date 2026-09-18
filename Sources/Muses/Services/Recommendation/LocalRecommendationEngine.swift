import Foundation

struct TrackRecommendationSnapshot: Sendable {
    let track: TrackSnapshot
    /// Stable YouTube Music artist identity. Display names are never a grouping key.
    let artistCatalogID: String?
    let playCount: Int
    let isFavorite: Bool
    let addedAt: Date
    let lastPlayedAt: Date?
}

struct LocalRecommendationInput: Sendable {
    let tracks: [TrackRecommendationSnapshot]
    let currentHour: Int
    let timeBand: ListeningContext.TimeBand
    let now: Date
}

/// Deterministic, device-only ranking. This type deliberately has no network
/// dependency and accepts only immutable values copied from SwiftData first.
struct LocalRecommendationEngine: Sendable {
    private let maximumItems = 16

    func plan(for input: LocalRecommendationInput) -> [HomeSection] {
        guard !input.tracks.isEmpty else { return [] }

        var sections: [HomeSection] = []
        let played = input.tracks.filter { $0.playCount > 0 || $0.lastPlayedAt != nil }
        let onRepeat = ranked(played, now: input.now).prefix(maximumItems)
        append(
            id: "muses:on-repeat",
            title: tr("On Repeat", "循环热播", zhHant: "循環熱播"),
            subtitle: tr("Recommended on this Mac", "由这台 Mac 推荐", zhHant: "由這台 Mac 推薦"),
            tracks: Array(onRepeat),
            to: &sections)

        let rediscover = input.tracks
            .filter { $0.playCount >= 2 && daysSince($0.lastPlayedAt, now: input.now) >= 21 }
            .sorted {
                rediscoveryScore($0, now: input.now) > rediscoveryScore($1, now: input.now)
            }
        append(
            id: "muses:rediscover",
            title: tr("Rediscover", "重新发现", zhHant: "重新發現"),
            subtitle: tr("Favorites worth returning to", "值得重温的熟悉旋律", zhHant: "值得重溫的熟悉旋律"),
            tracks: Array(rediscover.prefix(maximumItems)),
            to: &sections)

        let forgottenFavorites = input.tracks
            .filter { $0.isFavorite && daysSince($0.lastPlayedAt, now: input.now) >= 30 }
            .sorted { daysSince($0.lastPlayedAt, now: input.now) > daysSince($1.lastPlayedAt, now: input.now) }
        append(
            id: "muses:forgotten-favorites",
            title: tr("Forgotten Favorites", "被遗忘的喜爱", zhHant: "被遺忘的喜愛"),
            subtitle: tr("From your library", "来自你的资料库", zhHant: "來自你的資料庫"),
            tracks: Array(forgottenFavorites.prefix(maximumItems)),
            to: &sections)

        if let artist = strongestArtist(in: input.tracks) {
            let artistTracks = input.tracks
                .filter { $0.artistCatalogID == artist.id }
            append(
                id: "muses:artist:\(artist.id)",
                title: tr("Because you listen to \(artist.name)", "因为你常听 \(artist.name)", zhHant: "因為你常聽 \(artist.name)"),
                subtitle: tr("From your library", "来自你的资料库", zhHant: "來自你的資料庫"),
                tracks: Array(ranked(artistTracks, now: input.now).prefix(maximumItems)),
                to: &sections)
        }

        let recent = input.tracks.sorted {
            let left = contextScore($0, input: input)
            let right = contextScore($1, input: input)
            return left == right ? $0.addedAt > $1.addedAt : left > right
        }
        append(
            id: "muses:recently-added",
            title: tr("Recently Added", "最近添加", zhHant: "最近加入"),
            subtitle: tr("From your library", "来自你的资料库", zhHant: "來自你的資料庫"),
            tracks: Array(recent.prefix(maximumItems)),
            to: &sections)

        return sections
    }

    private func ranked(
        _ tracks: [TrackRecommendationSnapshot],
        now: Date
    ) -> [TrackRecommendationSnapshot] {
        tracks.sorted {
            let left = affinityScore($0, now: now)
            let right = affinityScore($1, now: now)
            return left == right
                ? $0.track.youTubeId < $1.track.youTubeId
                : left > right
        }
    }

    private func affinityScore(_ value: TrackRecommendationSnapshot, now: Date) -> Double {
        let age = daysSince(value.lastPlayedAt, now: now)
        let recentAffinity = value.lastPlayedAt == nil ? 0 : max(0, 1 - age / 30)
        let overplayPenalty = age < 1 && value.playCount > 8 ? 1.0 : 0.0
        return (value.isFavorite ? 4 : 0)
            + log1p(Double(value.playCount)) * 1.2
            + recentAffinity * 2
            + rediscoveryScore(value, now: now) * 1.5
            - overplayPenalty * 2
    }

    private func rediscoveryScore(_ value: TrackRecommendationSnapshot, now: Date) -> Double {
        guard value.playCount >= 2 else { return 0 }
        let familiarity = min(log1p(Double(value.playCount)) / 3, 1)
        return familiarity * min(daysSince(value.lastPlayedAt, now: now) / 90, 1)
    }

    private func daysSince(_ date: Date?, now: Date) -> Double {
        guard let date else { return 10_000 }
        return max(0, now.timeIntervalSince(date) / 86_400)
    }

    private func strongestArtist(in tracks: [TrackRecommendationSnapshot]) -> (id: String, name: String)? {
        var scores: [String: (display: String, score: Double)] = [:]
        for value in tracks where !value.track.artist.isEmpty {
            // Unresolved artists are intentionally omitted. Same-name artists can
            // belong to different YouTube channels and must not be merged.
            guard let key = value.artistCatalogID, !key.isEmpty else { continue }
            let score = log1p(Double(value.playCount)) + (value.isFavorite ? 2 : 0)
            let current = scores[key] ?? (value.track.artist, 0)
            scores[key] = (current.display, current.score + score)
        }
        guard let best = scores.max(by: { $0.value.score < $1.value.score }) else { return nil }
        return (best.key, best.value.display)
    }

    private func contextScore(_ value: TrackRecommendationSnapshot, input: LocalRecommendationInput) -> Double {
        let bandBonus: Double
        switch input.timeBand {
        case .morning: bandBonus = value.track.title.localizedCaseInsensitiveContains("acoustic") ? 2 : 0
        case .afternoon: bandBonus = value.track.title.localizedCaseInsensitiveContains("focus") ? 2 : 0
        case .evening: bandBonus = value.track.title.localizedCaseInsensitiveContains("live") ? 2 : 0
        case .lateNight: bandBonus = value.track.title.localizedCaseInsensitiveContains("sleep") ? 2 : 0
        }
        let hourBonus = Double((input.currentHour + value.track.youTubeId.utf8.reduce(0, { $0 + Int($1) })) % 7) / 100
        return affinityScore(value, now: input.now) + bandBonus + hourBonus
    }

    private func append(
        id: String,
        title: String,
        subtitle: String,
        tracks: [TrackRecommendationSnapshot],
        to sections: inout [HomeSection]
    ) {
        guard !tracks.isEmpty else { return }
        sections.append(HomeSection(
            id: id,
            title: title,
            subtitle: subtitle,
            kind: .youTubeCarousel,
            items: tracks.map { .track($0.track) },
            source: .localLibrary))
    }
}
