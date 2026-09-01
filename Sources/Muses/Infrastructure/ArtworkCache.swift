import Foundation
import CryptoKit

final class ArtworkCache: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static let `default`: ArtworkCache = {
        let base = URL.homeDirectory.appending(path: "Library/Caches/Muses/artwork")
        return ArtworkCache(directory: base)
    }()

    @discardableResult
    func store(_ data: Data) throws -> String {
        let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        let url = directory.appending(path: "\(hash).jpg")
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url)
        }
        return hash
    }

    func path(forHash hash: String) -> URL? {
        let url = directory.appending(path: "\(hash).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func data(forHash hash: String) -> Data? {
        guard let url = path(forHash: hash) else { return nil }
        return try? Data(contentsOf: url)
    }
}