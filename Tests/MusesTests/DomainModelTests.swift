import Foundation
import SwiftData
import Testing
@testable import Muses

@Model
final class SchemaReopenProbe {
    var name: String

    init(name: String) {
        self.name = name
    }
}

@Suite("Domain Models")
struct DomainModelTests {

    @Test("schema generation 2 drops Inbox, Automation, and Focus models")
    func schemaDropsRetiredModels() {
        #expect(MusesSchema.generation == 2)
        let names = Set(MusesSchema.models.map { String(describing: $0) })
        #expect(!names.contains("InboxItem"))
        #expect(!names.contains("AutomationRule"))
        #expect(!names.contains("FocusSession"))
        #expect(names.contains("Track"))
        #expect(names.contains("Playlist"))
        #expect(names.contains("ListeningEvent"))
    }

    @Test("generation 2 opens a prior on-disk store after an unused entity is dropped")
    func generation2OpensStoreAfterDroppingUnusedEntity() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "muses-schema-reopen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appending(path: "muses-youtube-native.sqlite")

        let prior = Schema(
            [Track.self, SchemaReopenProbe.self],
            version: Schema.Version(1, 0, 0)
        )
        let priorContainer = try ModelContainer(
            for: prior,
            configurations: ModelConfiguration(url: store)
        )
        let priorContext = ModelContext(priorContainer)
        priorContext.insert(Track(title: "kept", artist: "a", durationMs: 1, youTubeId: "kept-id"))
        priorContext.insert(SchemaReopenProbe(name: "retired"))
        try priorContext.save()

        let result = makeModelContainerWithFallback(storeURL: store)
        #expect(!result.usedInMemoryFallback)
        let tracks = try ModelContext(result.container).fetch(FetchDescriptor<Track>())
        #expect(tracks.contains(where: { $0.youTubeId == "kept-id" }))
    }


    @Test("EQBand is codable and equatable")
    func eqBandCodable() throws {
        let band = EQBand(frequency: 1000, gain: 3.0, q: 1.0)
        let data = try JSONEncoder().encode(band)
        let back = try JSONDecoder().decode(EQBand.self, from: data)
        #expect(back == band)
    }

    @Test("SpectrumFrame has 64 bands")
    func spectrumFrameBands() {
        let frame = SpectrumFrame(bands: Array(repeating: 0.5, count: 64), timestamp: 0)
        #expect(frame.bands.count == 64)
    }
}
