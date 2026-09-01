import Foundation
import SwiftData
import Observation

/// YouTube playlist import errors.
enum YouTubeImportError: LocalizedError, Equatable {
    /// The URL is not a valid YouTube playlist link (missing `list=` parameter).
    case invalidURL
    /// The fetched playlist is empty.
    case emptyPlaylist
    /// No `YouTubeImport` exists with the given id.
    case notFound
    /// Network/yt-dlp transport error, carrying a description.
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            tr("Could not parse YouTube playlist URL (missing list parameter)", "无法解析 YouTube 歌单 URL(缺少 list 参数)")
        case .emptyPlaylist:
            tr("Playlist is empty", "播放列表为空")
        case .notFound:
            tr("YouTube import record not found", "YouTube 导入记录未找到")
        case .networkError(let m):
            tr("Network error: \(m)", "网络错误:\(m)")
        }
    }

    static func == (lhs: YouTubeImportError, rhs: YouTubeImportError) -> Bool {
        String(describing: lhs) == String(describing: rhs)
    }
}

/// YouTube playlist import service.
///
/// Mirrors the `MetadataEnricherService` pattern: `@MainActor`, a fresh
/// `ModelContext(modelContainer)` per operation, networking through an injected `URLSession`,
/// covers persisted via `ArtworkCache`, and logging through `AppLog`.
///
/// Responsibilities:
///  - `importPlaylist(url:)` — fetches playlist entries via yt-dlp `--flat-playlist --dump-json`,
///   creating `YouTubeImport` + `YouTubeImportItem` + lazily created `.youtube`
///   `Track`s, and downloads the playlist cover (the first video's thumbnail).
@Observable
@MainActor
final class YouTubeImportService {
    private let bridge: any YTDlpBridgeProtocol
    private let modelContainer: ModelContainer
    private let artworkCache: ArtworkCache
    private let session: URLSession
    private weak var catalog: YouTubeCatalogService?
    private let log = AppLog.for("YouTubeImportService")

    init(bridge: any YTDlpBridgeProtocol,
         modelContainer: ModelContainer,
         artworkCache: ArtworkCache = .default,
         session: URLSession = .shared,
         catalog: YouTubeCatalogService? = nil) {
        self.bridge = bridge
        self.modelContainer = modelContainer
        self.artworkCache = artworkCache
        self.session = session
        self.catalog = catalog
    }

    // MARK: - Import

    /// Imports a YouTube playlist URL and returns the id of the new `YouTubeImport`.
    ///
    /// Flow:
    /// 1. `bridge.fetchPlaylist` fetches the flat-playlist entries.
    /// 2. Parses `list=` from the URL as `playlistId`; throws `.invalidURL` on failure.
    /// 3. Calls the YouTube oEmbed API for the playlist's real title/channel/cover; falls back to the first entry.
    /// 4. Creates the `YouTubeImport` plus an item and a lazy `.youtube` track per entry.
    /// 5. Sets the playlist cover URL (oEmbed or the first video's hqdefault), downloading and caching it (failure is non-blocking).
    func importPlaylist(url: String) async throws -> UUID {
        // 1. Parse playlistId. A repeated import reuses local truth without
        // reading or mutating remote state; explicit Check/Pull/Push owns sync.
        guard let playlistId = extractPlaylistId(from: url) else {
            throw YouTubeImportError.invalidURL
        }
        let existingCtx = ModelContext(modelContainer)
        if let existing = fetchImportByPlaylistId(playlistId, context: existingCtx) {
            return existing.id
        }

        // 2. Fetch entries.
        let entries: [YTDlpBridge.YTDlpPlaylistEntry]
        do {
            entries = try await bridge.fetchPlaylist(url: url, timeout: 60)
        } catch {
            log.error("fetchPlaylist failed: \(error.localizedDescription)")
            throw YouTubeImportError.networkError(error.localizedDescription)
        }

        // 3. Validate non-empty.
        guard !entries.isEmpty else {
            throw YouTubeImportError.emptyPlaylist
        }

        // 4. Fetch playlist metadata via oEmbed; fall back to the yt-dlp playlist_title, then a placeholder.
        let meta = await fetchOEmbedMetadata(for: url)
        let title = meta?.title
            ?? entries.compactMap(\.playlistTitle).first
            ?? "YouTube Playlist"
        let channel = meta?.channel ?? entries.first?.uploader ?? "Unknown"
        let oembedArtwork = meta?.artworkURL

        // 5. Create a fresh ModelContext.
        let ctx = ModelContext(modelContainer)

        // 6. Create the import.
        let imp = YouTubeImport(
            playlistId: playlistId,
            url: url,
            title: title,
            channel: channel
        )
        ctx.insert(imp)

        // 7. Create an item + lazy track per entry (reusing existing rows for the same youTubeId).
        var items: [YouTubeImportItem] = []
        for (index, entry) in entries.enumerated() {
            let durationMs = Int((entry.duration ?? 0) * 1000)
            let artist = entry.uploader ?? channel

            let item = YouTubeImportItem(
                youTubeId: entry.id,
                title: entry.title,
                artist: artist,
                durationMs: durationMs,
                order: index
            )
            ctx.insert(item)

            let track = track(for: entry, artist: artist, durationMs: durationMs, context: ctx)
            applyReleaseIdentityIfAvailable(track: track, playlistID: playlistId,
                                            order: index, title: title, artist: channel)
            item.track = track
            items.append(item)
        }
        imp.items = items

        // 8. Record the first sync time.
        imp.lastSyncedAt = Date()

        // 9. Playlist cover: prefer the oEmbed thumbnail, fall back to the first video's hqdefault; download and cache (non-blocking).
        let artworkURLString = oembedArtwork
            ?? (entries.first.map { thumbnailURL(forVideoId: $0.id) })
        if let artworkURLString {
            imp.artworkUrl = artworkURLString
            if let artworkURL = URL(string: artworkURLString) {
                if let imageData = await get(artworkURL) {
                    _ = try? artworkCache.store(imageData)
                }
            }
        }

        attachCatalogMetadata(for: imp, context: ctx)

        // 10. Save.
        try ctx.save()

        log.info("Imported playlist \(playlistId) (\(title)) with \(items.count) entries")
        return imp.id
    }

    // MARK: - Single video import

    /// Imports a single YouTube video as a `.youtube` track (returns the existing one for a known youTubeId).
    ///
    /// Fetches title/channel/cover via YouTube oEmbed (falling back to placeholders), creates the lazy track, and caches the cover.
    /// - Returns: the id of the new or existing track.
    @discardableResult
    func importVideo(url: String) async throws -> UUID {
        guard let videoId = extractVideoId(from: url) else {
            throw YouTubeImportError.invalidURL
        }

        let ctx = ModelContext(modelContainer)

        // Reuse the existing track (same youTubeId).
        if let existing = try? ctx.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.youTubeId == videoId }
        )).first {
            return existing.id
        }

        // Fetch metadata via oEmbed (fall back on failure).
        let meta = await fetchOEmbedMetadata(for: url)
        let title = meta?.title ?? "YouTube Video"
        let channel = meta?.channel ?? "Unknown"
        let artworkURLString = meta?.artworkURL ?? thumbnailURL(forVideoId: videoId)

        let track = Track(
            title: title,
            artist: channel,
            durationMs: 0,
            youTubeId: videoId,
            artworkUrl: artworkURLString
        )
        ctx.insert(track)

        // Cache the cover (non-blocking).
        if let url = URL(string: artworkURLString),
           let imageData = await get(url) {
            _ = try? artworkCache.store(imageData)
        }

        try ctx.save()
        log.info("Imported single video \(videoId) (\(title))")
        return track.id
    }

    // MARK: - Repair

    /// Collapse duplicate `.youtube` tracks that share a `youTubeId`, then
    /// rebuild only stable-ID YouTube catalog cache rows.
    func repairYouTubeLibrary() {
        let ctx = ModelContext(modelContainer)
        let all = (try? ctx.fetch(FetchDescriptor<Track>())) ?? []
        let grouped = Dictionary(grouping: all.compactMap { track -> (String, Track)? in
            guard !track.youTubeId.isEmpty else { return nil }
            return (track.youTubeId, track)
        }) { $0.0 }.mapValues { $0.map(\.1) }

        for (_, group) in grouped where group.count > 1 {
            mergeDuplicateYouTubeTracks(group, context: ctx)
        }

        let imports = (try? ctx.fetch(FetchDescriptor<YouTubeImport>())) ?? []
        for imp in imports {
            attachCatalogMetadata(for: imp, context: ctx)
        }
        try? ctx.save()
    }

    // MARK: - Remote item edits (owned playlists)

    /// Remove a YouTube-side item locally. Caller writes back to YouTube if owned.
    @discardableResult
    func removeRemoteItem(importId: UUID, itemId: UUID) -> Bool {
        let ctx = ModelContext(modelContainer)
        guard let imp = fetchImportById(importId, context: ctx) else { return false }
        guard let item = (imp.items ?? []).first(where: { $0.id == itemId }) else { return false }
        if var items = imp.items {
            items.removeAll { $0.id == itemId }
            for (idx, remaining) in items.sorted(by: { $0.order < $1.order }).enumerated() {
                remaining.order = idx
            }
            imp.items = items
        }
        ctx.delete(item)
        try? ctx.save()
        return true
    }

    /// Reorder YouTube-side items locally. Caller writes back to YouTube if owned.
    @discardableResult
    func moveRemoteItem(importId: UUID, from: Int, to: Int) -> Bool {
        let ctx = ModelContext(modelContainer)
        guard let imp = fetchImportById(importId, context: ctx) else { return false }
        var items = (imp.items ?? []).sorted { $0.order < $1.order }
        guard from < items.count, to <= items.count else { return false }
        let item = items.remove(at: from)
        items.insert(item, at: min(to, items.count))
        for (idx, item) in items.enumerated() { item.order = idx }
        imp.items = items
        try? ctx.save()
        return true
    }

    /// Append a YouTube video to this import (creates a lazy Track).
    @discardableResult
    func addRemoteVideo(importId: UUID, videoId: String, title: String, artist: String,
                        durationMs: Int = 0) -> Bool {
        let ctx = ModelContext(modelContainer)
        guard let imp = fetchImportById(importId, context: ctx) else { return false }
        if (imp.items ?? []).contains(where: { $0.youTubeId == videoId }) { return true }
        let nextOrder = (imp.items ?? []).map(\.order).max() ?? -1
        let item = YouTubeImportItem(
            youTubeId: videoId, title: title, artist: artist,
            durationMs: durationMs, order: nextOrder + 1)
        item.import_ = imp
        let track = track(for: .init(id: videoId, title: title, uploader: artist, duration: Double(durationMs) / 1000.0),
                          artist: artist, durationMs: durationMs, context: ctx)
        item.track = track
        ctx.insert(item)
        if var items = imp.items {
            items.append(item)
            imp.items = items
        } else {
            imp.items = [item]
        }
        try? ctx.save()
        return true
    }

    // MARK: - Helpers

    /// Fetches playlist metadata (title/channel/cover) from the YouTube oEmbed API.
    /// No API key required; returns nil on failure (404/network) so the caller falls back.
    ///
    /// - Parameter playlistURL: the playlist URL (including the `list=` parameter).
    /// - Returns: `(title, channel, artworkURL?)`, or nil.
    private func fetchOEmbedMetadata(for playlistURL: String) async -> (title: String, channel: String, artworkURL: String?)? {
        guard let encoded = playlistURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.youtube.com/oembed?url=\(encoded)&format=json") else {
            return nil
        }
        guard let data = await get(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = json["title"] as? String,
              let channel = json["author_name"] as? String else {
            log.warning("oEmbed parse failed or returned nothing; falling back to placeholder metadata")
            return nil
        }
        let artwork = json["thumbnail_url"] as? String
        return (title, channel, artwork)
    }

    /// Parses the `list=` parameter from a YouTube URL, returning the playlist id.
    /// Supports `youtube.com/playlist?list=`, `youtube.com/watch?v=...&list=...`,
    /// `youtu.be/<id>?list=...`, and similar shapes.
    private func extractPlaylistId(from url: String) -> String? {
        guard let comps = URLComponents(string: url) else { return nil }
        // 1) The standard query `list=` parameter.
        if let items = comps.queryItems {
            if let list = items.first(where: { $0.name == "list" })?.value,
               !list.isEmpty {
                return list
            }
        }
        // 2) Some youtu.be links place the list in the query; covered above.
        // 3) Without a list parameter, the playlist id is undeterminable.
        return nil
    }

    /// Parses a single-video id from a YouTube URL.
    /// Supports `youtube.com/watch?v=`, `youtu.be/<id>`, `youtube.com/shorts/<id>`, and `youtube.com/embed/<id>`.
    private func extractVideoId(from url: String) -> String? {
        guard let comps = URLComponents(string: url) else { return nil }
        if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return v
        }
        let host = (comps.host ?? "").lowercased()
        guard host.hasSuffix("youtube.com") || host == "youtu.be" else { return nil }
        let path = comps.path
        if host == "youtu.be" {
            let seg = path.split(separator: "/").filter { !$0.isEmpty }
            return seg.first.map { String($0) }
        }
        let seg = path.split(separator: "/").filter { !$0.isEmpty }
        guard let first = seg.first else { return nil }
        let prefix = first.lowercased()
        if prefix == "shorts" || prefix == "embed" {
            return seg.dropFirst().first.map { String($0) }
        }
        return nil
    }

    /// Builds the YouTube video thumbnail URL (hqdefault).
    private func thumbnailURL(forVideoId videoId: String) -> String {
        YouTubeThumbnail.urlString(videoId: videoId)
    }

    /// GETs a URL and returns the body data; transport errors or non-2xx return nil (never throws).
    private func get(_ url: URL) async -> Data? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                log.warning("GET \(url) returned non-2xx")
                return nil
            }
            return data
        } catch {
            log.error("GET \(url) 传输错误:\(error)")
            return nil
        }
    }

    /// Reuse an existing `.youtube` Track for this video id, or insert a new one.
    private func track(for entry: YTDlpBridge.YTDlpPlaylistEntry,
                       artist: String,
                       durationMs: Int,
                       context ctx: ModelContext) -> Track {
        if let existing = existingYouTubeTrack(videoId: entry.id, context: ctx) {
            if existing.title != entry.title { existing.title = entry.title }
            if existing.artist != artist { existing.artist = artist }
            if durationMs > 0, existing.durationMs != durationMs {
                existing.durationMs = durationMs
            }
            if existing.artworkUrl == nil {
                existing.artworkUrl = thumbnailURL(forVideoId: entry.id)
            }
            updateCatalogIdentity(track: existing, entry: entry)
            upsertCatalogArtist(stableID: existing.artistCatalogID, name: artist,
                                channelID: entry.channelID, context: ctx)
            return existing
        }
        let artistStableID = YouTubeCatalogIdentity.artist(
            channelID: entry.channelID, browseID: nil)
        let track = Track(
            title: entry.title,
            artist: artist,
            durationMs: durationMs,
            youTubeId: entry.id,
            artworkUrl: thumbnailURL(forVideoId: entry.id),
            mediaKind: entry.inferredMediaKind,
            artistCatalogID: artistStableID
        )
        ctx.insert(track)
        upsertCatalogArtist(stableID: artistStableID, name: artist,
                            channelID: entry.channelID, context: ctx)
        return track
    }

    private func existingYouTubeTrack(videoId: String, context ctx: ModelContext) -> Track? {
        let desc = FetchDescriptor<Track>(
            predicate: #Predicate { $0.youTubeId == videoId }
        )
        let found = (try? ctx.fetch(desc)) ?? []
        return Self.preferredTrack(among: found)
    }

    /// Prefer the row linked to an import item, then highest play count, then oldest.
    fileprivate static func preferredTrack(among tracks: [Track]) -> Track? {
        tracks.max { a, b in
            let aLinked = !(a.youTubeImportItems ?? []).isEmpty
            let bLinked = !(b.youTubeImportItems ?? []).isEmpty
            if aLinked != bLinked { return !aLinked && bLinked }
            if a.playCount != b.playCount { return a.playCount < b.playCount }
            let aPlayed = a.lastPlayedAt ?? .distantPast
            let bPlayed = b.lastPlayedAt ?? .distantPast
            if aPlayed != bPlayed { return aPlayed < bPlayed }
            return a.addedAt > b.addedAt
        }
    }

    private func mergeDuplicateYouTubeTracks(_ group: [Track], context ctx: ModelContext) {
        guard let keeper = Self.preferredTrack(among: group) else { return }
        let keeperId = keeper.id
        for discarded in group where discarded.id != keeperId {
            keeper.playCount += discarded.playCount
            if discarded.liked { keeper.liked = true }
            if let otherPlayed = discarded.lastPlayedAt {
                if let keptPlayed = keeper.lastPlayedAt {
                    if otherPlayed > keptPlayed { keeper.lastPlayedAt = otherPlayed }
                } else {
                    keeper.lastPlayedAt = otherPlayed
                }
            }
            for item in discarded.youTubeImportItems ?? [] { item.track = keeper }
            let discardedId = discarded.id
            let playlistItems = (try? ctx.fetch(FetchDescriptor<PlaylistItem>())) ?? []
            for item in playlistItems where item.track?.id == discardedId {
                item.track = keeper
            }
            let inboxItems = (try? ctx.fetch(FetchDescriptor<InboxItem>(
                predicate: #Predicate { $0.trackId == discardedId }
            ))) ?? []
            for item in inboxItems { item.trackId = keeperId }
            ctx.delete(discarded)
        }
    }

    private func attachCatalogMetadata(for imp: YouTubeImport, context ctx: ModelContext) {
        let tracks = (imp.items ?? []).compactMap(\.track)
        guard !tracks.isEmpty else { return }
        let albumTitle = imp.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let channel = imp.channel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channel.isEmpty, !albumTitle.isEmpty else { return }

        // Regular `PL…` imports stay playlists. Only a YouTube Music album ID
        // becomes a release; title/artist text is never used as identity.
        guard YouTubePlaylistID.isMusicAlbum(imp.playlistId), !albumTitle.isEmpty else { return }
        guard let stableID = YouTubeCatalogIdentity.release(
            browseID: nil, playlistID: imp.playlistId) else { return }
        let artistStableIDs = Set(tracks.compactMap(\.artistCatalogID))
        let artistStableID = artistStableIDs.count == 1 ? artistStableIDs.first : nil
        let key = stableID
        let descriptor = FetchDescriptor<CatalogRelease>(predicate: #Predicate { $0.stableID == key })
        let release = (try? ctx.fetch(descriptor).first)
            ?? CatalogRelease(stableID: stableID, title: albumTitle, artistName: channel)
        if release.modelContext == nil { ctx.insert(release) }
        release.title = albumTitle
        release.artistName = channel
        release.artistStableID = artistStableID
        release.artworkURL = imp.artworkUrl
        release.refreshedAt = imp.lastSyncedAt ?? .init()
        release.unavailable = false

        for (index, item) in (imp.items ?? []).sorted(by: { $0.order < $1.order }).enumerated() {
            guard let track = item.track else { continue }
            track.releaseCatalogID = stableID
            track.releaseOrder = item.order
            if track.albumTitle == nil || track.albumTitle?.isEmpty == true { track.albumTitle = albumTitle }
            if track.albumArtist == nil || track.albumArtist?.isEmpty == true { track.albumArtist = channel }
            if item.order < 0 { track.releaseOrder = index }
        }
    }

    private func applyReleaseIdentityIfAvailable(track: Track, playlistID: String,
                                                 order: Int, title: String, artist: String) {
        guard YouTubePlaylistID.isMusicAlbum(playlistID),
              let stableID = YouTubeCatalogIdentity.release(
                browseID: nil, playlistID: playlistID) else { return }
        track.releaseCatalogID = stableID
        track.releaseOrder = order
        if track.albumTitle == nil || track.albumTitle?.isEmpty == true { track.albumTitle = title }
        if track.albumArtist == nil || track.albumArtist?.isEmpty == true { track.albumArtist = artist }
    }

    private func updateCatalogIdentity(track: Track, entry: YTDlpBridge.YTDlpPlaylistEntry) {
        track.mediaKind = entry.inferredMediaKind
        if let artistStableID = YouTubeCatalogIdentity.artist(
            channelID: entry.channelID, browseID: nil) {
            track.artistCatalogID = artistStableID
        }
    }

    private func upsertCatalogArtist(stableID: String?, name: String,
                                     channelID: String?, context ctx: ModelContext) {
        guard let stableID else { return }
        let key = stableID
        let descriptor = FetchDescriptor<CatalogArtist>(predicate: #Predicate { $0.stableID == key })
        let artist = (try? ctx.fetch(descriptor).first)
            ?? CatalogArtist(stableID: stableID, name: name, channelID: channelID)
        if artist.modelContext == nil { ctx.insert(artist) }
        artist.name = name
        artist.channelID = channelID
        artist.refreshedAt = .init()
        artist.unavailable = false
    }

    /// Fetches a `YouTubeImport` by id (fresh context).
    private func fetchImportById(_ id: UUID, context ctx: ModelContext) -> YouTubeImport? {
        let descriptor = FetchDescriptor<YouTubeImport>(
            predicate: #Predicate { $0.id == id }
        )
        return try? ctx.fetch(descriptor).first
    }

    private func fetchImportByPlaylistId(_ playlistId: String, context ctx: ModelContext) -> YouTubeImport? {
        let descriptor = FetchDescriptor<YouTubeImport>(
            predicate: #Predicate { $0.playlistId == playlistId }
        )
        return try? ctx.fetch(descriptor).first
    }

    /// Fetches a `Track` by id (fresh context).
    private func fetchTrackById(_ id: UUID, context ctx: ModelContext) -> Track? {
        let descriptor = FetchDescriptor<Track>(
            predicate: #Predicate { $0.id == id }
        )
        return try? ctx.fetch(descriptor).first
    }
}
