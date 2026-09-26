import Foundation
import SwiftData
import os

func musesDefaultStoreURL() -> URL {
    MusesDataPaths.applicationSupport.appending(path: "muses-youtube-native.sqlite")
}

func makeModelContainer(inMemory: Bool = false, storeURL: URL? = nil) throws -> ModelContainer {
    let configuration: ModelConfiguration
    if inMemory {
        configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    } else {
        let url = storeURL ?? musesDefaultStoreURL()
        if storeURL == nil {
            try MusesDataPaths.prepareDataDirectory()
            let legacy = MusesDataPaths.legacyApplicationSupport
                .appending(path: "muses-youtube-native.sqlite")
            try relocateLegacyStoreIfNeeded(from: legacy, to: url)
        } else {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        _ = try StoreUpgradeSnapshot.prepareIfNeeded(at: url)
        configuration = ModelConfiguration(url: url)
    }
    return try ModelContainer(for: MusesSchema.current, configurations: configuration)
}

/// A consistent SQLite backup activates the new path only after quick_check.
/// The legacy store stays intact until a separate cold-restart cleanup gate.
func relocateLegacyStoreIfNeeded(from source: URL, to destination: URL) throws {
    let fm = FileManager.default
    guard !fm.fileExists(atPath: destination.path),
          fm.fileExists(atPath: source.path) else { return }
    try StoreUpgradeSnapshot.restore(snapshot: source, to: destination)
}

func makeCurrentModelContainer(inMemory: Bool = false,
                               storeURL: URL? = nil) throws -> ModelContainer {
    try makeModelContainer(inMemory: inMemory, storeURL: storeURL)
}

struct MusesStoreLoadResult {
    let container: ModelContainer
    let usedInMemoryFallback: Bool
    let failureDescription: String?

    init(container: ModelContainer, usedInMemoryFallback: Bool,
         failureDescription: String? = nil) {
        self.container = container
        self.usedInMemoryFallback = usedInMemoryFallback
        self.failureDescription = failureDescription
    }
}

/// The production entry point opens only the validated YouTube-native store.
@MainActor
func makeYouTubeNativeModelContainerWithFallback(
    storeURL: URL? = nil
) -> MusesStoreLoadResult {
    makeModelContainerWithFallback(storeURL: storeURL)
}

func makeModelContainerWithFallback(storeURL: URL? = nil) -> MusesStoreLoadResult {
    let destination = storeURL ?? musesDefaultStoreURL()
    do {
        return MusesStoreLoadResult(
            container: try makeModelContainer(storeURL: storeURL),
            usedInMemoryFallback: false)
    } catch {
        let log = AppLog.for("MusesModelContainer")
        log.error("Final YouTube-native store failed to open: \(error.localizedDescription)")
        backupCorruptStore(at: destination)
        do {
            return MusesStoreLoadResult(
                container: try makeModelContainer(inMemory: true),
                usedInMemoryFallback: true,
                failureDescription: error.localizedDescription)
        } catch {
            fatalError("Muses cannot construct a ModelContainer: \(error)")
        }
    }
}

/// Preserve an unreadable final store before falling back to an empty in-memory session.
func backupCorruptStore(at storeURL: URL) {
    let directory = storeURL.deletingLastPathComponent()
    let stem = storeURL.deletingPathExtension().lastPathComponent
    let ext = storeURL.pathExtension
    let stamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
    for suffix in ["", "-wal", "-shm"] {
        let source = URL(fileURLWithPath: storeURL.path + suffix)
        let backup = directory.appending(path: "\(stem)-corrupt-\(stamp).\(ext)\(suffix)")
        guard FileManager.default.fileExists(atPath: source.path),
              !FileManager.default.fileExists(atPath: backup.path) else { continue }
        try? FileManager.default.copyItem(at: source, to: backup)
    }
}
