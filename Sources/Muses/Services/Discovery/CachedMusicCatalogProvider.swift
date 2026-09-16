import CryptoKit
import Foundation

/// Rebuildable, anonymous display cache. Only normalized values are encoded:
/// no raw responses, search terms, filter parameters or continuation tokens.
actor CachedMusicCatalogProvider: MusicCatalogProviding {
    private struct Record: Codable {
        let version: Int
        let items: [MusicCatalogItem]
        let relatedItems: [MusicCatalogItem]?
        let fetchedAt: Date
        let region: String
    }
    private let upstream: any MusicCatalogProviding
    private let directory: URL
    private let region: String
    private var generation = UUID()

    init(upstream: any MusicCatalogProviding = PublicMusicCatalogProvider(),
         directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Muses/public-catalog/v1"), region: String = "US") {
        self.upstream = upstream
        self.directory = directory
        self.region = region
    }

    func reset() async {
        generation = UUID()
        await upstream.reset()
    }

    func search(_ query: String, kind: MusicCatalogKind?) async throws -> MusicCatalogPage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 1_000 else { throw MusicCatalogError.invalidIdentity }
        let key = "search|\(kind?.rawValue ?? "all")|\(query)"
        let expected = generation
        do {
            let page = try await upstream.search(query, kind: kind)
            try check(expected)
            save(page, key: key)
            return page
        } catch {
            try check(expected)
            if let page = read(key) { return page }
            throw error
        }
    }

    func browse(_ id: String) async throws -> MusicCatalogPage {
        let key = "browse|\(id)"
        let expected = generation
        do {
            let page = try await upstream.browse(id)
            try check(expected)
            save(page, key: key)
            return page
        } catch {
            try check(expected)
            if let page = read(key) { return page }
            throw error
        }
    }

    // A failed page must not masquerade as the cached first page. Keep the
    // existing browser rows and cursor so the caller can retry this exact page.
    func next(_ cursor: MusicCatalogCursor) async throws -> MusicCatalogPage {
        let expected = generation
        let page = try await upstream.next(cursor)
        try check(expected)
        return page
    }

    private func check(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw MusicCatalogError.expiredCursor }
    }

    private func url(_ key: String) -> URL {
        let digest = SHA256.hash(data: Data((region + "|" + key).utf8))
        return directory.appending(path: digest.map { String(format: "%02x", $0) }.joined() + ".json")
    }

    private func read(_ key: String) -> MusicCatalogPage? {
        let file = url(key)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 2 * 1_024 * 1_024,
              let data = try? Data(contentsOf: file),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == 1, record.region == region,
              record.items.count <= 500, (record.relatedItems?.count ?? 0) <= 500 else { return nil }
        return .init(items: record.items, filters: [], next: nil,
                     fetchedAt: record.fetchedAt, region: record.region,
                     relatedItems: record.relatedItems ?? [], isStale: true, refreshFailed: true)
    }

    private func save(_ page: MusicCatalogPage, key: String) {
        guard !page.isStale, page.region == region, page.items.count <= 500, page.relatedItems.count <= 500,
              let data = try? JSONEncoder().encode(Record(version: 1, items: page.items, relatedItems: page.relatedItems, fetchedAt: page.fetchedAt, region: region)),
              data.count <= 2 * 1_024 * 1_024 else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = url(key)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            // Bound disk usage to 100 pages; network order and saved time are
            // not rewritten when a stale page is displayed.
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "json" }
                .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for old in files.dropFirst(100) { try? FileManager.default.removeItem(at: old) }
        } catch {
            // Cache failure never turns a successful network response into an error.
        }
    }
}
