import CryptoKit
import Foundation

/// Rebuildable, anonymous display cache. Only normalized values are encoded:
/// no raw responses, search terms, filter parameters or continuation tokens.
actor CachedMusicCatalogProvider: MusicCatalogProviding {
    private struct Record: Codable {
        let version: Int
        let items: [MusicCatalogItem]
        let relatedItems: [MusicCatalogItem]?
        let metadata: MusicCatalogMetadata?
        let fetchedAt: Date
        let region: String
        let language: String
    }
    private let upstream: any MusicCatalogProviding
    private let directory: URL
    private let region: String
    private let language: String
    private let staleLifetime: TimeInterval
    private let now: @Sendable () -> Date
    private var generation = UUID()

    init(upstream: (any MusicCatalogProviding)? = nil,
         directory: URL = MusesDataPaths.caches.appending(path: "public-catalog/v2"),
         region: String = "US", language: String = "en",
         staleLifetime: TimeInterval = 7 * 24 * 60 * 60,
         now: @escaping @Sendable () -> Date = Date.init) {
        let normalizedRegion = Self.normalizedRegion(region)
        let normalizedLanguage = Self.normalizedLanguage(language)
        self.upstream = upstream ?? PublicMusicCatalogProvider(
            region: normalizedRegion, language: normalizedLanguage)
        self.region = normalizedRegion
        self.language = normalizedLanguage
        self.directory = directory
            .appending(path: Self.partitionComponent(normalizedLanguage))
            .appending(path: Self.partitionComponent(normalizedRegion))
        self.staleLifetime = staleLifetime
        self.now = now
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
        let digest = SHA256.hash(data: Data(key.utf8))
        return directory.appending(path: digest.map { String(format: "%02x", $0) }.joined() + ".json")
    }

    private func read(_ key: String) -> MusicCatalogPage? {
        let file = url(key)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 2 * 1_024 * 1_024,
              let data = try? Data(contentsOf: file),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == 2, record.region == region,
              record.language == language,
              record.items.count <= 500, (record.relatedItems?.count ?? 0) <= 500 else {
            return nil
        }
        let age = now().timeIntervalSince(record.fetchedAt)
        guard age >= 0, age <= staleLifetime else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return .init(items: record.items, filters: [], next: nil,
                     fetchedAt: record.fetchedAt, region: record.region,
                     language: record.language,
                     relatedItems: record.relatedItems ?? [], metadata: record.metadata,
                     isStale: true, refreshFailed: true)
    }

    private func save(_ page: MusicCatalogPage, key: String) {
        guard !page.isStale, page.region == region,
              page.language == language,
              page.items.count <= 500, page.relatedItems.count <= 500,
              let data = try? JSONEncoder().encode(Record(
                version: 2, items: page.items,
                relatedItems: page.relatedItems,
                metadata: page.metadata,
                fetchedAt: page.fetchedAt, region: region,
                language: language)),
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

    private nonisolated static func partitionComponent(_ value: String) -> String {
        let allowed = value.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "-"
        }
        let result = String(String.UnicodeScalarView(allowed))
        return result.isEmpty ? "unknown" : String(result.prefix(40))
    }

    private nonisolated static func normalizedRegion(_ value: String) -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return result.count == 2 ? result : "US"
    }

    private nonisolated static func normalizedLanguage(_ value: String) -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        return result.isEmpty ? "en" : result
    }
}
