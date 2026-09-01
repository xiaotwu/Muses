import Foundation

final class WaveformCache: @unchecked Sendable {
    let directory: URL
    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    static let `default` = WaveformCache(directory:
        URL.homeDirectory.appending(path: "Library/Caches/Muses/waveforms"))

    func path(forTrackId id: UUID) -> URL { directory.appending(path: "\(id.uuidString).wave") }

    func load(forTrackId id: UUID) -> [Float]? {
        let url = path(forTrackId: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    func save(_ peaks: [Float], forTrackId id: UUID) throws {
        let url = path(forTrackId: id)
        let data = Data(buffer: peaks.withUnsafeBufferPointer { $0 })
        try data.write(to: url)
    }
}