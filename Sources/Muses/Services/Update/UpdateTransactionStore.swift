import Foundation
import Sparkle

/// Minimal durable handoff; no download history is retained after acknowledgment.
@MainActor
final class UpdateTransactionStore {
    static let key = "muses.updates.pendingTransaction"
    struct Transaction: Codable {
        let id: UUID
        let targetBuild: String
    }
    private let defaults: UserDefaults
    private let cleanup: () throws -> Void

    init(defaults: UserDefaults, cleanup: (() throws -> Void)? = nil) {
        self.defaults = defaults
        self.cleanup = cleanup ?? {
            guard let id = Bundle.main.bundleIdentifier,
                  id == "com.muses.app" || MusesDataPaths.acceptanceNamespace(bundleID: id) != nil else {
                throw UpdateFailure.unsafeCleanupPath
            }
            try Self.cleanPersistentDownloads(bundleID: id)
        }
    }

    func begin(targetBuild: String) throws {
        guard !targetBuild.isEmpty else { throw UpdateFailure.stateNotReady }
        if let data = defaults.data(forKey: Self.key),
           let pending = try? JSONDecoder().decode(Transaction.self, from: data),
           pending.targetBuild == targetBuild { return }
        let data = try JSONEncoder().encode(Transaction(id: UUID(), targetBuild: targetBuild))
        defaults.set(data, forKey: Self.key)
    }

    func acknowledgeSuccessfulLaunch(build: String) throws {
        guard let data = defaults.data(forKey: Self.key) else { return }
        let pending = try JSONDecoder().decode(Transaction.self, from: data)
        guard SUStandardVersionComparator.default.compareVersion(build, toVersion: pending.targetBuild) != .orderedAscending else {
            return
        }
        try cleanup()
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: PrefKey.latestKnownVersion)
        defaults.removeObject(forKey: PrefKey.lastUpdateCheckAt)
    }

    /// Source-verified path for pinned Sparkle 2.10.0. The installer owns Installation/
    /// and removes it itself; never race or remove a live installer's directory.
    /// com.muses.app ends in .app, so Sparkle appends .sparkle to its cache identifier.
    static func cleanPersistentDownloads(bundleID: String, caches: URL? = nil) throws {
        guard bundleID == "com.muses.app" || MusesDataPaths.acceptanceNamespace(bundleID: bundleID) != nil else {
            throw UpdateFailure.unsafeCleanupPath
        }
        let fm = FileManager.default
        let base = caches ?? fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let component = bundleID.lowercased().hasSuffix(".app") ? bundleID + ".sparkle" : bundleID
        var path = base
        for name in [component, "org.sparkle-project.Sparkle", "PersistentDownloads"] {
            path.appendPathComponent(name, isDirectory: true)
            // Reject symbolic links, including dangling links, before any recursive removal.
            let attributes: [FileAttributeKey: Any]
            do { attributes = try fm.attributesOfItem(atPath: path.path) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                return
            }
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw UpdateFailure.unsafeCleanupPath
            }
        }
        for item in try fm.contentsOfDirectory(at: path, includingPropertiesForKeys: nil) {
            // removeItem removes a child symlink itself, without following it.
            try fm.removeItem(at: item)
        }
    }
}
