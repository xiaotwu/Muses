import Foundation

/// Conservative public-discovery gate for Home. yt-dlp search has no durable
/// "official" flag, so unverified chart, playlist, cover, and mix results are
/// never presented as a YouTube Music recommendation. Account data bypasses
/// this gate because it already comes from the signed-in user's official API
/// snapshot.
enum YouTubeMusicTrust {
    private static let promotionalMarkers = [
        "spotify", "tiktok", "top hits", "trending songs", "music mix",
        "playlist", "cover", "remix", "lofi", "chill mix", "study music",
        "roadtrip", "workout mix"
    ]

    private static let officialMarkers = [
        "official audio", "official music video", "official video",
        "official lyric video", "official visualizer"
    ]

    static func isTrustedHomeEntry(_ entry: YTDlpBridge.YTDlpPlaylistEntry) -> Bool {
        guard !entry.id.isEmpty,
              !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (entry.duration ?? 0) >= 20 else { return false }

        let title = entry.title.lowercased()
        let uploader = (entry.uploader ?? "").lowercased()
        guard !promotionalMarkers.contains(where: title.contains) else { return false }

        if entry.track != nil || entry.album != nil { return true }
        if uploader.hasSuffix(" - topic") || uploader.hasSuffix("- topic") { return true }

        // An "Official Audio" suffix is self-asserted metadata, not a
        // verification signal on its own. Public search frequently returns
        // reuploads with that text. Keep it only when the uploader identity
        // can be tied back to the credited lead artist in the title.
        guard officialMarkers.contains(where: title.contains) else { return false }
        return uploaderMatchesCreditedArtist(uploader: uploader, title: title)
    }

    private static func uploaderMatchesCreditedArtist(uploader: String, title: String) -> Bool {
        guard !uploader.isEmpty else { return false }
        guard let separator = title.firstIndex(where: { "-—–:".contains($0) }) else {
            return false
        }
        let artistPrefix = String(title[..<separator])
        let normalizedArtist = normalized(artistPrefix)
        let normalizedUploader = normalized(uploader)
        guard normalizedArtist.count >= 3, normalizedUploader.count >= 3 else { return false }
        return normalizedArtist.contains(normalizedUploader)
            || normalizedUploader.contains(normalizedArtist)
    }

    private static func normalized(_ value: String) -> String {
        value.unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
            .lowercased()
    }
}
