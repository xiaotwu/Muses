import Foundation

struct LyricsCandidate: Decodable, Sendable, Identifiable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?

    var hasLyrics: Bool {
        instrumental != true && (plainLyrics?.isEmpty == false || syncedLyrics?.isEmpty == false)
    }
}

/// Conservative recording matching. A plausible title alone is insufficient:
/// live, cover, remix, instrumental and speed variants must agree as well.
enum LyricsMatchPolicy {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func queryArtist(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*-\s*Topic$|VEVO$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func artist(_ text: String) -> String { normalized(queryArtist(text)) }

    static func title(_ text: String, artist artistName: String) -> String {
        var title = normalized(LyricsService.sanitizedTitle(text))
        let artist = artist(artistName)
        if !artist.isEmpty, title.hasPrefix(artist + " ") {
            title = String(title.dropFirst(artist.count + 1))
        }
        return title
    }

    static func versions(_ title: String) -> Set<String> {
        let text = " " + normalized(title) + " "
        let markers = ["live", "cover", "remix", "acoustic", "instrumental", "karaoke", "slowed", "sped up", "remaster"]
        return Set(markers.filter { text.contains(" " + $0 + " ") || ($0 == "remaster" && text.contains(" remastered ")) })
    }

    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 1 }
        let a = Set(lhs.split(separator: " ")), b = Set(rhs.split(separator: " "))
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    static func score(_ candidate: LyricsCandidate, track: TrackSnapshot) -> Double {
        guard candidate.hasLyrics, versions(track.title) == versions(candidate.trackName) else { return 0 }
        let artistScore = similarity(artist(track.artist), artist(candidate.artistName))
        let titleScore = similarity(title(track.title, artist: track.artist), title(candidate.trackName, artist: candidate.artistName))
        guard artistScore >= 0.6, titleScore >= 0.65 else { return 0 }
        var durationScore = 0.0
        if let duration = candidate.duration, duration > 0, track.durationSeconds > 0 {
            let delta = abs(duration - track.durationSeconds)
            guard delta <= max(8, track.durationSeconds * 0.04) else { return 0 }
            durationScore = max(0, 1 - delta / max(8, track.durationSeconds * 0.04))
        }
        return 0.5 * titleScore + 0.35 * artistScore + 0.15 * durationScore
    }

    static func ranked(_ candidates: [LyricsCandidate], track: TrackSnapshot) -> [LyricsCandidate] {
        candidates.filter(\.hasLyrics).sorted {
            let a = score($0, track: track), b = score($1, track: track)
            return a == b ? $0.id < $1.id : a > b
        }
    }

    static func automatic(_ candidates: [LyricsCandidate], track: TrackSnapshot) -> LyricsCandidate? {
        let ranked = ranked(candidates, track: track)
        guard let first = ranked.first, score(first, track: track) >= 0.86 else { return nil }
        if ranked.count > 1 {
            let second = ranked[1]
            let sameLyrics = first.plainLyrics == second.plainLyrics && first.syncedLyrics == second.syncedLyrics
            guard sameLyrics || score(first, track: track) - score(second, track: track) >= 0.06 else { return nil }
        }
        return first
    }
}

/// Synchronization is provider evidence, never a language-model estimate.
@MainActor
enum LyricsSyncUpgrade {
    static func match(_ cached: LyricsResult, candidates: [LyricsCandidate],
                      track: TrackSnapshot) -> LyricsCandidate? {
        guard let plain = cached.plainLyrics, !plain.isEmpty else { return nil }
        let expected = LyricsMatchPolicy.normalized(plain)
        let eligible = candidates.filter { candidate in
            guard let synced = candidate.syncedLyrics else { return false }
            let lines = LyricsService.parseLRC(synced)
            guard lines.contains(where: { $0.time != nil }) else { return false }
            let text = lines.map(\.text).joined(separator: " ")
            return LyricsMatchPolicy.normalized(text) == expected
        }
        return LyricsMatchPolicy.automatic(eligible, track: track)
    }
}
