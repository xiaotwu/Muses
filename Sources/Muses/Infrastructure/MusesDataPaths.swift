import Foundation

/// App-managed files live under ~/.muses. Disposable acceptance bundles use
/// distinct roots even without App Sandbox. System preferences and OAuth tokens
/// remain in UserDefaults and Keychain respectively.
enum MusesDataPaths {
    static func acceptanceNamespace(bundleID: String?) -> String? {
        guard let bundleID, bundleID.hasPrefix("com.muses.acceptance."),
              bundleID.count <= 120,
              bundleID.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0)
                      || (97...122).contains($0) || $0 == 46 || $0 == 45
              }) else { return nil }
        return bundleID
    }

    static var isAcceptance: Bool {
        acceptanceNamespace(bundleID: Bundle.main.bundleIdentifier) != nil
    }

    static func legacyDirectory(in base: URL, bundleID: String?) -> URL {
        if let namespace = acceptanceNamespace(bundleID: bundleID) {
            return base.appending(path: "MusesAcceptance/\(namespace)", directoryHint: .isDirectory)
        }
        return base.appending(path: "Muses", directoryHint: .isDirectory)
    }

    static func root(bundleID: String?) -> URL {
        let base = URL.homeDirectory.appending(path: ".muses", directoryHint: .isDirectory)
        guard let namespace = acceptanceNamespace(bundleID: bundleID) else { return base }
        return base.appending(path: "acceptance/\(namespace)", directoryHint: .isDirectory)
    }

    static func dataDirectory(bundleID: String?) -> URL {
        root(bundleID: bundleID).appending(path: "data", directoryHint: .isDirectory)
    }

    static func cacheDirectory(bundleID: String?) -> URL {
        root(bundleID: bundleID).appending(path: "cache", directoryHint: .isDirectory)
    }

    static var applicationSupport: URL {
        dataDirectory(bundleID: Bundle.main.bundleIdentifier)
    }

    static var caches: URL {
        cacheDirectory(bundleID: Bundle.main.bundleIdentifier)
    }

    static var legacyApplicationSupport: URL {
        legacyDirectory(in: URL.homeDirectory.appending(path: "Library/Application Support"),
                        bundleID: Bundle.main.bundleIdentifier)
    }

    static var legacyCaches: URL {
        legacyDirectory(in: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0],
                        bundleID: Bundle.main.bundleIdentifier)
    }

    static func prepareDataDirectory() throws {
        try prepareRoot()
        try FileManager.default.createDirectory(at: applicationSupport,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private static func prepareRoot() throws {
        let fm = FileManager.default
        let base = URL.homeDirectory.appending(path: ".muses", directoryHint: .isDirectory)
        try fm.createDirectory(at: base, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        if isAcceptance {
            let destination = root(bundleID: Bundle.main.bundleIdentifier)
            try fm.createDirectory(at: destination, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
    }

    /// Cache files are rebuildable, but moving an existing cache avoids a cold
    /// artwork/media redownload. The rename is atomic on the user's volume.
    static func prepareCacheDirectory() throws {
        let fm = FileManager.default
        let destination = caches
        let source = legacyCaches
        try prepareRoot()
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: destination.path), fm.fileExists(atPath: source.path) {
            try fm.moveItem(at: source, to: destination)
        } else if !fm.fileExists(atPath: destination.path) {
            try fm.createDirectory(at: destination, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        } else if fm.fileExists(atPath: source.path) {
            try mergeCacheDirectory(from: source, to: destination)
        }
    }

    /// An interrupted or earlier launch can create the new root before migration.
    /// Keep newer cache entries on collisions; the old entries are rebuildable.
    static func mergeCacheDirectory(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let target = destination.appending(path: item.lastPathComponent)
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true && values.isSymbolicLink != true,
               fm.fileExists(atPath: target.path) {
                let targetValues = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if targetValues.isDirectory == true && targetValues.isSymbolicLink != true {
                    try mergeCacheDirectory(from: item, to: target)
                    continue
                }
            }
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: item)
            } else {
                try fm.moveItem(at: item, to: target)
            }
        }
        try fm.removeItem(at: source)
    }
}
