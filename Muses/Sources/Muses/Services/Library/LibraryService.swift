import Foundation
import SwiftData
import Observation

struct ScanProgress: Equatable {
    var scanned: Int
    var total: Int
    var currentPath: String?
}

@Observable
@MainActor
final class LibraryService {
    let modelContainer: ModelContainer
    let metadata: MetadataService
    let scanner = DirectoryScanner()

    var scanProgress: ScanProgress = .init(scanned: 0, total: 0, currentPath: nil)

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

    private func scan(root: ScanRoot) async {
        let rootURL = URL(fileURLWithPath: root.path)
        // AsyncStream 不是 Sequence, 必须用 `for await` 收集。
        var urls: [URL] = []
        for await url in scanner.enumerateAudio(at: rootURL) {
            urls.append(url)
        }
        var scanned = 0
        scanProgress = .init(scanned: 0, total: urls.count, currentPath: nil)

        // Capture the Sendable metadata service so child tasks can read off the main actor.
        let metadataService = self.metadata
        await withTaskGroup(of: (URL, EmbeddedMetadata?).self) { group in
            var iter = urls.makeIterator()
            for _ in 0..<8 {
                if let url = iter.next() {
                    group.addTask { (url, await metadataService.readEmbedded(at: url)) }
                }
            }
            for await (url, meta) in group {
                scanned += 1
                scanProgress.scanned = scanned
                scanProgress.currentPath = url.path
                if let meta = meta {
                    self.upsert(url: url, meta: meta)
                }
                if let url = iter.next() {
                    group.addTask { (url, await metadataService.readEmbedded(at: url)) }
                }
            }
        }
        let ctx = ModelContext(modelContainer)
        if let r = try? ctx.fetch(FetchDescriptor<ScanRoot>()).first(where: { $0.path == root.path }) {
            r.lastScannedAt = .init()
            try? ctx.save()
        }
        scanProgress = .init(scanned: scanned, total: urls.count, currentPath: nil)
    }

    private func upsert(url: URL, meta: EmbeddedMetadata) {
        let ctx = ModelContext(modelContainer)
        let path = url.path
        let existing = try? ctx.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.filePath == path })).first

        var artworkHash: String?
        if let data = meta.artworkData {
            artworkHash = try? ArtworkCache.default.store(data)
        }

        if let existing = existing {
            // 更新元数据, 保留 playCount/liked
            existing.title = meta.title ?? url.deletingPathExtension().lastPathComponent
            existing.artist = meta.artist ?? "Unknown Artist"
            existing.albumTitle = meta.albumTitle
            existing.albumArtist = meta.albumArtist
            existing.durationMs = meta.durationMs
            existing.trackNo = meta.trackNo; existing.discNo = meta.discNo
            existing.year = meta.year; existing.genre = meta.genre
            existing.sampleRate = meta.sampleRate; existing.bitDepth = meta.bitDepth
            existing.codec = meta.codec; existing.isLossless = meta.isLossless
            existing.localArtworkHash = artworkHash ?? existing.localArtworkHash
            existing.availabilityRaw = TrackAvailability.available.rawValue
            existing.metadataStatusRaw = MetadataStatus.complete.rawValue
            existing.fileModificationDate = nil
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
            localArtworkHash: artworkHash, lyrics: nil,
            sampleRate: meta.sampleRate, bitDepth: meta.bitDepth,
            codec: meta.codec, isLossless: meta.isLossless,
            metadataStatus: .complete, availability: .available
        )
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
}