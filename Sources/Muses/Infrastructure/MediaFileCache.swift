import Foundation

/// On-disk yt-dlp media, keyed by video id + quality.
enum MediaFileCache {
    static var directory: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Muses/streams", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func sanitizedQuality(_ quality: String) -> String {
        quality.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    static func file(videoId: String, quality: String, ext: String) -> URL {
        directory.appendingPathComponent("\(videoId)__\(sanitizedQuality(quality)).\(ext)")
    }

    /// First existing file for this video+quality larger than 4 KB.
    static func existing(videoId: String, quality: String) -> URL? {
        let prefix = "\(videoId)__\(sanitizedQuality(quality))."
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        let match = items.first { url in
            let name = url.lastPathComponent
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return size > 4096 && name.hasPrefix(prefix)
        }
        return match
    }

    static func remove(videoId: String, quality: String) {
        let prefix = "\(videoId)__\(sanitizedQuality(quality))."
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for url in items where url.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func totalBytes() -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(Int64(0)) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + Int64(size)
        }
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
