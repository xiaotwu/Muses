import Foundation
import SwiftData
import Observation

struct ScanProgress: Equatable {
    var scanned: Int
    var total: Int
    var currentPath: String?
}

/// Result of scanning a single URL off the main actor.
/// `meta` is nil when the file is unchanged (skip) or when metadata reading failed.
private struct ScanWorkItem: Sendable {
    enum Action: Sendable { case skip, update, insert }
    let url: URL
    let fileMtime: Date?
    let meta: EmbeddedMetadata?
    let action: Action
}

@Observable
@MainActor
final class LibraryService {
    let modelContainer: ModelContainer
    let metadata: MetadataService
    let scanner = DirectoryScanner()
    var enricher: MetadataEnricherService?

    var scanProgress: ScanProgress = .init(scanned: 0, total: 0, currentPath: nil)
    /// Bumped on every `toggleLike` so views observing LibraryService re-render.
    var likedRevision: Int = 0
    /// Bumped on every `updateTrack` so views observing LibraryService re-render.
    var metadataRevision: Int = 0
    /// Bumped on every pin/unpin so views re-render.
    var pinRevision: Int = 0

    init(modelContainer: ModelContainer, metadata: MetadataService) {
        self.modelContainer = modelContainer
        self.metadata = metadata
    }

    func addScanRoot(_ url: URL, watch: Bool) async throws {
        let ctx = ModelContext(modelContainer)
        let root = ScanRoot(path: url.path, watch: watch)
        ctx.insert(root)
        try ctx.save()
        await scan(root: root)
    }

    func rescan() async {
        let ctx = ModelContext(modelContainer)
        let roots = (try? ctx.fetch(FetchDescriptor<ScanRoot>())) ?? []
        for root in roots { await scan(root: root) }
    }

    /// One-shot import of dropped files/folders. Scans directories for audio,
    /// reads embedded metadata, and upserts — without registering a ScanRoot.
    func importURLs(_ urls: [URL]) async {
        var audioURLs: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                for await audioURL in scanner.enumerateAudio(at: url) {
                    audioURLs.append(audioURL)
                }
            } else if DirectoryScanner.extensions.contains(url.pathExtension.lowercased()) {
                audioURLs.append(url)
            }
        }
        guard !audioURLs.isEmpty else { return }

        let metadataService = self.metadata
        var scanned = 0
        scanProgress = .init(scanned: 0, total: audioURLs.count, currentPath: nil)
        await withTaskGroup(of: ScanWorkItem.self) { group in
            var iter = audioURLs.makeIterator()
            for _ in 0..<8 {
                if let url = iter.next() {
                    group.addTask {
                        let fm = FileManager.default
                        let fileMtime = try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
                        let meta = await metadataService.readEmbedded(at: url)
                        return ScanWorkItem(url: url, fileMtime: fileMtime, meta: meta, action: .insert)
                    }
                }
            }
            for await item in group {
                scanned += 1
                scanProgress.scanned = scanned
                scanProgress.currentPath = item.url.path
                if let meta = item.meta {
                    upsert(url: item.url, meta: meta, fileMtime: item.fileMtime)
                }
                if let url = iter.next() {
                    group.addTask {
                        let fm = FileManager.default
                        let fileMtime = try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
                        let meta = await metadataService.readEmbedded(at: url)
                        return ScanWorkItem(url: url, fileMtime: fileMtime, meta: meta, action: .insert)
                    }
                }
            }
        }
        scanProgress = .init(scanned: scanned, total: audioURLs.count, currentPath: nil)
        backfillArtists()
        triggerArtistEnrichment()
    }

    private func scan(root: ScanRoot) async {
        // Resolve symlinks so the prefix comparison against scanner-yielded URLs
        // (which FileManager resolves) matches track.filePath values.
        let rootURL = URL(fileURLWithPath: root.path).resolvingSymlinksInPath()
        let resolvedRootPath = rootURL.path
        // AsyncStream 不是 Sequence, 必须用 `for await` 收集。
        var urls: [URL] = []
        for await url in scanner.enumerateAudio(at: rootURL) {
            urls.append(url)
        }
        let scannedPaths = Set(urls.map { $0.path })

        // Incremental scan: build a map of existing tracks' stored mtime by filePath,
        // so child tasks can skip re-reading metadata when the file is unchanged.
        let existingTracks: [Track] = (try? ModelContext(modelContainer).fetch(FetchDescriptor<Track>())) ?? []
        var existingMtimeByPath: [String: Date] = [:]
        for t in existingTracks {
            if let p = t.filePath, let m = t.fileModificationDate {
                existingMtimeByPath[p] = m
            }
        }

        var scanned = 0
        scanProgress = .init(scanned: 0, total: urls.count, currentPath: nil)

        // Capture the Sendable metadata service so child tasks can read off the main actor.
        let metadataService = self.metadata
        await withTaskGroup(of: ScanWorkItem.self) { group in
            var iter = urls.makeIterator()
            for _ in 0..<8 {
                if let url = iter.next() {
                    let knownMtime = existingMtimeByPath[url.path]
                    group.addTask {
                        let fm = FileManager.default
                        let fileMtime = try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
                        // Unchanged file: skip the expensive AVAsset read.
                        if let knownMtime = knownMtime, let fileMtime = fileMtime, knownMtime == fileMtime {
                            return ScanWorkItem(url: url, fileMtime: fileMtime, meta: nil, action: .skip)
                        }
                        let meta = await metadataService.readEmbedded(at: url)
                        let action: ScanWorkItem.Action = (knownMtime != nil) ? .update : .insert
                        return ScanWorkItem(url: url, fileMtime: fileMtime, meta: meta, action: action)
                    }
                }
            }
            for await item in group {
                scanned += 1
                scanProgress.scanned = scanned
                scanProgress.currentPath = item.url.path
                self.applyScanItem(item)
                if let url = iter.next() {
                    let knownMtime = existingMtimeByPath[url.path]
                    group.addTask {
                        let fm = FileManager.default
                        let fileMtime = try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
                        if let knownMtime = knownMtime, let fileMtime = fileMtime, knownMtime == fileMtime {
                            return ScanWorkItem(url: url, fileMtime: fileMtime, meta: nil, action: .skip)
                        }
                        let meta = await metadataService.readEmbedded(at: url)
                        let action: ScanWorkItem.Action = (knownMtime != nil) ? .update : .insert
                        return ScanWorkItem(url: url, fileMtime: fileMtime, meta: meta, action: action)
                    }
                }
            }
        }

        // Soft-delete: mark tracks under this root whose path was NOT scanned as unavailable.
        markMissingAsUnavailable(rootPath: resolvedRootPath, scannedPaths: scannedPaths)

        let ctx = ModelContext(modelContainer)
        if let r = try? ctx.fetch(FetchDescriptor<ScanRoot>()).first(where: { $0.path == root.path }) {
            r.lastScannedAt = .init()
            try? ctx.save()
        }
        scanProgress = .init(scanned: scanned, total: urls.count, currentPath: nil)
        // 扫描完成后异步补全缺封面的曲目(联网 iTunes/MusicBrainz)
        triggerEnrichment()
        // 增量 back-fill 新扫描产生的 Artist 实体
        backfillArtists()
        triggerArtistEnrichment()
    }

    /// 查找 metadataStatus == .embedded 且缺封面/专辑名的曲目, 并发限 4 调 enricher。
    private func triggerEnrichment() {
        guard let enricher else { return }
        let ctx = ModelContext(modelContainer)
        let candidates = (try? ctx.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.metadataStatusRaw == "embedded" && ($0.localArtworkHash == nil || $0.albumTitle == nil) }
        ))) ?? []
        guard !candidates.isEmpty else { return }
        let trackIds = candidates.map(\.id)
        Task { [enricher] in
            await withTaskGroup(of: Void.self) { group in
                var iter = trackIds.makeIterator()
                for _ in 0..<4 {
                    if let id = iter.next() {
                        group.addTask { await enricher.enrich(trackId: id) }
                    }
                }
                for await _ in group {
                    if let id = iter.next() {
                        group.addTask { await enricher.enrich(trackId: id) }
                    }
                }
            }
        }
    }

    /// 并发限 4 对缺图片的 Artist 调 enricher.enrichArtist。
    func triggerArtistEnrichment() {
        guard let enricher else { return }
        let ctx = ModelContext(modelContainer)
        let candidates = (try? ctx.fetch(FetchDescriptor<Artist>(
            predicate: #Predicate { $0.artworkHash == nil }
        ))) ?? []
        guard !candidates.isEmpty else { return }
        let artistIds = candidates.map(\.id)
        Task { [enricher] in
            await withTaskGroup(of: Void.self) { group in
                var iter = artistIds.makeIterator()
                for _ in 0..<4 {
                    if let id = iter.next() {
                        group.addTask { await enricher.enrichArtist(artistId: id) }
                    }
                }
                for await _ in group {
                    if let id = iter.next() {
                        group.addTask { await enricher.enrichArtist(artistId: id) }
                    }
                }
            }
        }
    }

    private func applyScanItem(_ item: ScanWorkItem) {
        switch item.action {
        case .skip:
            // File unchanged: don't re-read metadata, but ensure the track is still
            // marked available (it may have been soft-deleted on a prior scan).
            markAvailable(filePath: item.url.path)
        case .insert, .update:
            if let meta = item.meta {
                upsert(url: item.url, meta: meta, fileMtime: item.fileMtime)
            }
        }
    }

    private func markAvailable(filePath: String) {
        let ctx = ModelContext(modelContainer)
        if let t = try? ctx.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.filePath == filePath })).first {
            t.availabilityRaw = TrackAvailability.available.rawValue
            try? ctx.save()
        }
    }

    /// Mark tracks whose file has disappeared from disk as `.unavailable` (soft delete).
    /// Does not remove them from the store; `purgeUnavailable()` later deletes the ones that
    /// are still gone. We check by file existence rather than path-prefix matching because
    /// FileManager.enumerator resolves firmlinks (e.g. /var -> /private/var on macOS),
    /// which makes string-prefix comparisons against the stored ScanRoot path unreliable.
    private func markMissingAsUnavailable(rootPath: String, scannedPaths: Set<String>) {
        let ctx = ModelContext(modelContainer)
        // Narrow to tracks likely under this root: compare against `rootPath` AND its
        // canonical form so firmlinked roots (e.g. /var vs /private/var) both match.
        let canonicalRoot = canonicalPath(rootPath)
        let candidates = (try? ctx.fetch(FetchDescriptor<Track>())) ?? []
        for t in candidates {
            guard let p = t.filePath else { continue }
            let ct = canonicalPath(p)
            let underRoot = ct.hasPrefix(canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/")
            // Mark unavailable if the file is gone from disk. (A file that still exists but
            // was simply skipped from enumeration would remain available.)
            if underRoot && !FileManager.default.fileExists(atPath: p) {
                t.availabilityRaw = TrackAvailability.unavailable.rawValue
            }
        }
        try? ctx.save()
    }

    /// Best-effort canonical path: resolves symlinks and, for the macOS /var firmlink,
    /// also yields the /private-prefixed form via realpath.
    private func canonicalPath(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        // FileManager.enumerator resolves /var -> /private/var; mirror that here so paths
        // stored from enumerator match paths derived from the unresolved ScanRoot.
        if resolved.hasPrefix("/var/") {
            return "/private" + resolved
        }
        return resolved
    }

    private func upsert(url: URL, meta: EmbeddedMetadata, fileMtime: Date?) {
        let ctx = ModelContext(modelContainer)
        let path = url.path
        let existing = try? ctx.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.filePath == path })).first

        var artworkHash: String?
        if let data = meta.artworkData {
            artworkHash = try? ArtworkCache.default.store(data)
        }

        if let existing = existing {
            // 更新元数据, 保留 playCount/liked; record the new mtime so the next
            // scan can skip re-reading if the file is unchanged.
            existing.title = meta.title ?? url.deletingPathExtension().lastPathComponent
            existing.artist = meta.artist ?? "Unknown Artist"
            existing.albumTitle = meta.albumTitle
            existing.albumArtist = meta.albumArtist
            existing.durationMs = meta.durationMs
            existing.trackNo = meta.trackNo; existing.discNo = meta.discNo
            existing.year = meta.year; existing.genre = meta.genre
            existing.sampleRate = meta.sampleRate; existing.bitDepth = meta.bitDepth
            existing.codec = meta.codec; existing.isLossless = meta.isLossless
            existing.replayGain = meta.replayGain
            existing.localArtworkHash = artworkHash ?? existing.localArtworkHash
            existing.availabilityRaw = TrackAvailability.available.rawValue
            existing.metadataStatusRaw = MetadataStatus.complete.rawValue
            existing.fileModificationDate = fileMtime
            try? ctx.save()
            return
        }

        let track = Track(
            source: .local,
            title: meta.title ?? url.deletingPathExtension().lastPathComponent,
            artist: meta.artist ?? "Unknown Artist",
            albumTitle: meta.albumTitle,
            albumArtist: meta.albumArtist ?? meta.artist,
            durationMs: meta.durationMs,
            trackNo: meta.trackNo, discNo: meta.discNo, year: meta.year, genre: meta.genre,
            filePath: path, youTubeId: nil, artworkUrl: nil,
            localArtworkHash: artworkHash, lyrics: nil, replayGain: meta.replayGain,
            sampleRate: meta.sampleRate, bitDepth: meta.bitDepth,
            codec: meta.codec, isLossless: meta.isLossless,
            metadataStatus: .complete, availability: .available
        )
        track.fileModificationDate = fileMtime
        ctx.insert(track)

        // 聚合到 Album
        let albumTitle = meta.albumTitle ?? "Various"
        let albumArtist = meta.albumArtist ?? meta.artist ?? "Unknown Artist"
        let isVarious = (meta.albumTitle == nil)
        let album = (try? ctx.fetch(FetchDescriptor<Album>(
            predicate: #Predicate { $0.title == albumTitle && $0.albumArtist == albumArtist })).first)
            ?? {
                let a = Album(title: albumTitle, albumArtist: albumArtist,
                              year: meta.year, isVarious: isVarious)
                ctx.insert(a); return a
            }()
        album.tracks.append(track)
        track.album = album
        try? ctx.save()
    }

    func purgeUnavailable() throws {
        let ctx = ModelContext(modelContainer)
        let unavailable = (try? ctx.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.availabilityRaw == "unavailable" }))) ?? []
        for t in unavailable {
            if let path = t.filePath, !FileManager.default.fileExists(atPath: path) {
                ctx.delete(t)
            }
        }
        try ctx.save()
    }

    func allAlbums() -> [Album] {
        let ctx = ModelContext(modelContainer)
        return ((try? ctx.fetch(FetchDescriptor<Album>())) ?? []).sorted { $0.title < $1.title }
    }

    /// 幂等 back-fill:从 `Album.albumArtist` 去重创建 Artist 实体并链接 albums/tracks。
    /// 首次启动及后续新增扫描后均安全调用 — 只创建尚不存在的 Artist、只链接尚未链接的 album/track。
    func backfillArtists() {
        let ctx = ModelContext(modelContainer)
        let albums = (try? ctx.fetch(FetchDescriptor<Album>())) ?? []
        guard !albums.isEmpty else { return }

        // 已有 Artist 按名索引(避免重复创建)
        let existing = (try? ctx.fetch(FetchDescriptor<Artist>())) ?? []
        var byName: [String: Artist] = [:]
        for a in existing { byName[a.name] = a }

        for album in albums {
            let name = album.albumArtist.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let artist = byName[name] ?? {
                let a = Artist(name: name)
                ctx.insert(a)
                byName[name] = a
                return a
            }()
            if album.artistRef == nil { album.artistRef = artist }
            for t in album.tracks where t.artistRef == nil { t.artistRef = artist }
        }
        try? ctx.save()
    }

    /// 所有 Artist 实体,按名称排序。
    func allArtists() -> [Artist] {
        let ctx = ModelContext(modelContainer)
        let desc = FetchDescriptor<Artist>(sortBy: [SortDescriptor(\.name)])
        return (try? ctx.fetch(desc)) ?? []
    }

    func albums(byArtist artist: Artist) -> [Album] {
        let ctx = ModelContext(modelContainer)
        let id = artist.id
        guard let fetched = try? ctx.fetch(FetchDescriptor<Artist>(
            predicate: #Predicate { $0.id == id })).first else { return [] }
        return fetched.albums.sorted { $0.title < $1.title }
    }

    func tracks(byArtist artist: Artist) -> [Track] {
        let ctx = ModelContext(modelContainer)
        let id = artist.id
        guard let fetched = try? ctx.fetch(FetchDescriptor<Artist>(
            predicate: #Predicate { $0.id == id })).first else { return [] }
        return fetched.tracks.sorted { (a, b) in
            (a.albumTitle ?? "", a.trackNo ?? 0) < (b.albumTitle ?? "", b.trackNo ?? 0)
        }
    }

    func allTracks() -> [Track] {
        let ctx = ModelContext(modelContainer)
        return (try? ctx.fetch(FetchDescriptor<Track>())) ?? []
    }

    /// All tracks optionally filtered by a case-insensitive search query matched
    /// against title, artist, and albumTitle. Sorted by title.
    ///
    /// 注:`localizedStandardContains` 下推到 `#Predicate` 在当前 SwiftData
    /// 版本对可选字符串的 SQL 生成不稳定(静默返回空),故仍取全量在 Swift
    /// 侧过滤;搜索词为空时直接返回排序结果,避免无谓过滤。
    func allTracks(search: String?) -> [Track] {
        let ctx = ModelContext(modelContainer)
        let all = (try? ctx.fetch(FetchDescriptor<Track>(
            sortBy: [SortDescriptor(\.title)]))) ?? []
        guard let q = search?.trimmingCharacters(in: .whitespaces), !q.isEmpty else { return all }
        return all.filter { t in
            t.title.localizedCaseInsensitiveContains(q)
            || t.artist.localizedCaseInsensitiveContains(q)
            || (t.albumTitle ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    /// Re-fetch the track by id in a fresh context, flip `liked`, and save.
    /// Mirrors `markAvailable` — the caller's `Track` may belong to a different context.
    func toggleLike(_ track: Track) { toggleLike(id: track.id) }

    func toggleLike(id: UUID) {
        let ctx = ModelContext(modelContainer)
        guard let t = try? ctx.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.id == id })).first else { return }
        t.liked.toggle()
        try? ctx.save()
        likedRevision += 1
    }

    /// 更新曲目元数据(fresh context re-fetch + mutate + save)。
    /// 仅修改 DB,不写文件标签。bump metadataRevision 以刷新 UI。
    func updateTrack(id: UUID, title: String, artist: String,
                      albumTitle: String?, albumArtist: String?,
                      trackNo: Int?, discNo: Int?, year: Int?,
                      genre: String?, lyrics: String?) {
        let ctx = ModelContext(modelContainer)
        guard let t = try? ctx.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.id == id })).first else { return }
        t.title = title
        t.artist = artist
        t.albumTitle = albumTitle
        t.albumArtist = albumArtist
        t.trackNo = trackNo
        t.discNo = discNo
        t.year = year
        t.genre = genre
        t.lyrics = lyrics
        try? ctx.save()
        metadataRevision += 1
    }

    func isLiked(id: UUID) -> Bool {
        let ctx = ModelContext(modelContainer)
        return ((try? ctx.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.id == id })).first)?.liked) ?? false
    }

    /// 批量查询已喜欢曲目 id 集合:一次 fetch 替代 N 次 `isLiked(id:)` 调用,
    /// 避免每行渲染都新建 ModelContext。视图在 `.onAppear` /
    /// `.onChange(of: likedRevision)` 时构造一次,行内用 `contains` O(1) 查询。
    func likedIDs(for ids: [UUID]) -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        let ctx = ModelContext(modelContainer)
        let desc = FetchDescriptor<Track>(
            predicate: #Predicate { ids.contains($0.id) && $0.liked == true })
        let liked = (try? ctx.fetch(desc)) ?? []
        return Set(liked.map(\.id))
    }

    func likedTracks() -> [Track] {
        let ctx = ModelContext(modelContainer)
        let desc = FetchDescriptor<Track>(
            predicate: #Predicate { $0.liked == true },
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)])
        return (try? ctx.fetch(desc)) ?? []
    }

    /// Return the album's tracks sorted by (discNo, trackNo). Re-fetches the album in a
    /// fresh ModelContext so the returned `Track` objects are valid for this context.
    func tracks(in album: Album) -> [Track] {
        let ctx = ModelContext(modelContainer)
        let id = album.id
        guard let fetched = try? ctx.fetch(FetchDescriptor<Album>(
            predicate: #Predicate { $0.id == id })).first else { return [] }
        return fetched.tracks.sorted { (a, b) in
            (a.discNo ?? 0, a.trackNo ?? 0) < (b.discNo ?? 0, b.trackNo ?? 0)
        }
    }

    // MARK: - 钉选

    /// 切换专辑钉选状态(fresh context re-fetch + mutate + save)。
    func togglePin(_ album: Album) {
        let ctx = ModelContext(modelContainer)
        let id = album.id
        guard let a = try? ctx.fetch(FetchDescriptor<Album>(
            predicate: #Predicate { $0.id == id })).first else { return }
        a.pinned.toggle()
        try? ctx.save()
        pinRevision += 1
    }

    /// 获取已钉选专辑(按标题排序)。
    func pinnedAlbums() -> [Album] {
        let ctx = ModelContext(modelContainer)
        let desc = FetchDescriptor<Album>(
            predicate: #Predicate { $0.pinned == true },
            sortBy: [SortDescriptor(\.title)])
        return (try? ctx.fetch(desc)) ?? []
    }

    /// 判断专辑是否已钉选。
    func isPinned(_ album: Album) -> Bool {
        let ctx = ModelContext(modelContainer)
        let id = album.id
        return ((try? ctx.fetch(FetchDescriptor<Album>(
            predicate: #Predicate { $0.id == id })).first)?.pinned) ?? false
    }

    /// 批量查询已钉选专辑 id 集合:一次 fetch 替代 N 次 `isPinned` 调用。
    func pinnedIDs(for ids: [UUID]) -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        let ctx = ModelContext(modelContainer)
        let desc = FetchDescriptor<Album>(
            predicate: #Predicate { ids.contains($0.id) && $0.pinned == true })
        let pinned = (try? ctx.fetch(desc)) ?? []
        return Set(pinned.map(\.id))
    }

    /// 获取最近播放的专辑(有 lastPlayedAt 的曲目所属专辑)。
    func mostRecentlyPlayedAlbum() -> Album? {
        let ctx = ModelContext(modelContainer)
        let desc = FetchDescriptor<Track>(
            predicate: #Predicate { $0.lastPlayedAt != nil },
            sortBy: [SortDescriptor(\.lastPlayedAt, order: .reverse)]
        )
        guard let track = try? ctx.fetch(desc).first else { return nil }
        return track.album
    }
}