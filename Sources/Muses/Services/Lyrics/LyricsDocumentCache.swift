import CryptoKit
import Foundation

enum LyricsDocumentIdentity {
    static func digest(_ values: [String]) -> String {
        let data = (try? JSONEncoder().encode(values)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func key(for track: TrackSnapshot) -> String {
        digest([track.youTubeId, track.title, track.artist, track.albumTitle ?? "", String(track.durationSeconds)])
    }
}

/// Rebuildable, bounded documents retain provider provenance without changing
/// SwiftData user truth. All filesystem work stays off the main actor.
actor LyricsDocumentCache {
    private let directory: URL

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "Muses/lyrics/v2")) {
        self.directory = directory
    }

    func read(key: String) -> LyricsResult? {
        guard key.count == 64, key.allSatisfy(\.isHexDigit) else { return nil }
        let url = directory.appendingPathComponent(key + ".json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size < 2_000_000, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LyricsResult.self, from: data)
    }

    func write(_ result: LyricsResult, key: String) {
        guard key.count == 64, key.allSatisfy(\.isHexDigit),
              let data = try? JSONEncoder().encode(result), data.count < 2_000_000 else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(key + ".json"), options: .atomic)
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "json" }
                .sorted {
                    ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                }
            for file in files.dropFirst(100) { try? FileManager.default.removeItem(at: file) }
        } catch {
            // Cache failure never blocks displaying an already retrieved document.
        }
    }
}
