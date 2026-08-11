import Testing
import Foundation
import SwiftData
@testable import Muses

@MainActor
@Suite("LibraryService")
struct LibraryServiceTests {
    @Test("scans a directory and creates tracks")
    func scanCreatesTracks() async throws {
        let container = try makeModelContainer(inMemory: true)
        let svc = LibraryService(modelContainer: container, metadata: MetadataService(
            artworkCache: ArtworkCache(directory: FileManager.default.temporaryDirectory
                .appending(path: "muses-lib-test"))))

        // 构造含一个真实音频的临时目录(复用 Task4 fixture 或运行时生成一个 wav)
        let dir = FileManager.default.temporaryDirectory.appending(path: "muses-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appending(path: "tone.wav")
        try makeSilentWav(at: wav, seconds: 1)

        try await svc.addScanRoot(dir, watch: false)
        let albums = svc.allAlbums()
        #expect(albums.count >= 1)  // 至少一个专辑(可能 Various)
        let tracks = svc.allTracks()
        #expect(tracks.count == 1)
    }
}

func makeSilentWav(at url: URL, seconds: Int) throws {
    // 写最小有效 WAV(44100 16bit mono, 全 0)
    let sampleCount = 44100 * seconds
    var data = Data()
    let totalBytes = 36 + sampleCount * 2
    data.append(contentsOf: "RIFF".utf8)
    data.append(contentsOf: UInt32(totalBytes).littleEndianBytes)
    data.append(contentsOf: "WAVE".utf8)
    data.append(contentsOf: "fmt ".utf8)
    data.append(contentsOf: UInt32(16).littleEndianBytes)
    data.append(contentsOf: UInt16(1).littleEndianBytes)   // PCM
    data.append(contentsOf: UInt16(1).littleEndianBytes)   // mono
    data.append(contentsOf: UInt32(44100).littleEndianBytes)
    data.append(contentsOf: UInt32(88200).littleEndianBytes)
    data.append(contentsOf: UInt16(2).littleEndianBytes)
    data.append(contentsOf: UInt16(16).littleEndianBytes)
    data.append(contentsOf: "data".utf8)
    data.append(contentsOf: UInt32(sampleCount * 2).littleEndianBytes)
    data.append(Data(repeating: 0, count: sampleCount * 2))
    try data.write(to: url)
}

extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}

extension LibraryService {
    func allTracks() -> [Track] {
        let ctx = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Track>()
        return (try? ctx.fetch(descriptor)) ?? []
    }
}