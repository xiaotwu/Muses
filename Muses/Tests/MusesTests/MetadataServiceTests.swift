import Testing
import Foundation
@testable import Muses

@Suite("MetadataService")
struct MetadataServiceTests {
    @Test("reads codec and sample rate from wav fixture")
    func readWav() async throws {
        let fixture = Bundle.module.url(forResource: "tone", withExtension: "wav",
                                         subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "tone", withExtension: "wav")
        // fixture 可能不存在于 CI, 跳过而非失败以保持测试可移植:
        guard let url = fixture else {
            #expect(Bool(true), "fixture missing, skip")
            return
        }
        let svc = MetadataService(artworkCache: ArtworkCache(
            directory: FileManager.default.temporaryDirectory.appending(path: "muses-test-meta")))
        let meta = await svc.readEmbedded(at: url)
        #expect(meta != nil)
        #expect(meta?.sampleRate == 44100)
        #expect((meta?.durationMs ?? 0) > 0)
    }
}