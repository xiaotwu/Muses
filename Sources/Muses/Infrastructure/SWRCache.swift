import Foundation
import CryptoKit

/// Generic stale-while-revalidate cache: memory plus disk JSON, with a
/// `fetchedAt` timestamp.
///
/// Semantics:
///  - `get(_:)` returns the cached value and its age (fresh or stale); the
///    caller decides whether to refresh in the background.
///  - `set(_:value:)` writes to memory and persists asynchronously.
///  - `isFresh(age:freshWindow:)` checks whether the value is inside the fresh window.
///
/// `T` must be `Codable & Sendable`. Disk files live at `{dir}/{key-hex}.json`;
/// keys are normalized with SHA-256 to avoid illegal characters. `@MainActor`
/// matches `StreamURLCache`; disk I/O runs in a detached task so the main
/// thread is never blocked.
@MainActor
final class SWRCache<T: Codable & Sendable> {
    struct Cached: Sendable {
        let value: T
        let fetchedAt: Date
        var age: TimeInterval { Date().timeIntervalSince(fetchedAt) }
    }

    private struct DiskEnvelope: Codable {
        let value: T
        let fetchedAt: Date
    }

    private let memory: NSCache<NSString, CacheBox> = .init()
    private let directory: URL

    /// Box for the in-memory value (NSCache stores reference types).
    final class CacheBox {
        let cached: Cached
        init(_ cached: Cached) { self.cached = cached }
    }

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory,
                                                  withIntermediateDirectories: true)
    }

    /// Reads the cached value (memory first, falling back to disk). nil if not cached.
    func get(_ key: String) -> Cached? {
        let nsKey = key as NSString
        if let box = memory.object(forKey: nsKey) {
            return box.cached
        }
        // Backfill memory from disk.
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(DiskEnvelope.self, from: data) else {
            return nil
        }
        let cached = Cached(value: envelope.value, fetchedAt: envelope.fetchedAt)
        memory.setObject(CacheBox(cached), forKey: nsKey)
        return cached
    }

    /// Writes to memory and persists to disk asynchronously.
    func set(_ key: String, value: T, fetchedAt: Date = .init()) {
        let cached = Cached(value: value, fetchedAt: fetchedAt)
        memory.setObject(CacheBox(cached), forKey: key as NSString)
        let envelope = DiskEnvelope(value: value, fetchedAt: fetchedAt)
        let url = fileURL(for: key)
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(envelope) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Invalidates a key (memory + disk).
    func invalidate(_ key: String) {
        memory.removeObject(forKey: key as NSString)
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    /// Clears everything (memory; disk files are removed as needed).
    func clearAll() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory,
                                                  withIntermediateDirectories: true)
    }

    func isFresh(_ cached: Cached, freshWindow: TimeInterval) -> Bool {
        cached.age <= freshWindow
    }

    private func fileURL(for key: String) -> URL {
        let hash = SHA256Hex(key)
        return directory.appendingPathComponent("\(hash).json")
    }
}

/// SHA-256 hex string (normalizes cache keys).
func SHA256Hex(_ s: String) -> String {
    let data = Data(s.utf8)
    let digest = Array(SHA256.hash(data: data))
    return digest.map { String(format: "%02x", $0) }.joined()
}