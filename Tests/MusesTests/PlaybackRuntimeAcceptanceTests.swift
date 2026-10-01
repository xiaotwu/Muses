import Foundation
import SwiftData
import Testing
@testable import Muses

/// Opt-in fixture for real app/network checks, never a production store.
@MainActor
@Suite("Playback runtime acceptance")
struct PlaybackRuntimeAcceptanceTests {
    @Test("Seed disposable 1001-item distant-selection fixture")
    func seedDistantSelections() throws {
        guard ProcessInfo.processInfo.environment["MUSES_SEED_DISTANT_PLAYBACK"] == "1" else { return }
        let directory = URL(fileURLWithPath: "/tmp/muses-input-acceptance").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = directory.appending(path: "migration-ui-fixture.sqlite")
        let container = try makeModelContainer(storeURL: store)
        let context = ModelContext(container)
        guard try context.fetchCount(FetchDescriptor<YouTubeImport>()) == 0 else { return }
        let imported = YouTubeImport(playlistId: "PL_muses_runtime_fixture", url: "https://www.youtube.com/playlist?list=PL_muses_runtime_fixture",
                                     title: "Distant Playback Acceptance", channel: "Runtime fixture")
        context.insert(imported)
        let media: [Int: (String, String, String, Int)] = [
            0: ("aqz-KE-bpKQ", "Big Buck Bunny", "Blender", 596_000),
            500: ("9bZkp7q19f0", "Gangnam Style", "PSY", 253_000),
            1000: ("kJQP7kiw5Fk", "Despacito", "Luis Fonsi", 282_000)
        ]
        var items: [YouTubeImportItem] = []
        for index in 0...1000 {
            let value = media[index]
            let id = value?.0 ?? String(format: "muses%06d", index)
            let title = String(format: "%04d · ", index) + (value?.1 ?? "Synthetic position — do not play")
            let item = YouTubeImportItem(youTubeId: id, title: title, artist: value?.2 ?? "Synthetic", durationMs: value?.3 ?? 0, order: index)
            context.insert(item)
            item.import_ = imported
            if let value {
                let track = Track(title: title, artist: value.2, durationMs: value.3, youTubeId: id)
                context.insert(track)
                item.track = track
            }
            items.append(item)
        }
        imported.items = items
        try context.save()
        #expect(items.count == 1001)
        #expect(try context.fetchCount(FetchDescriptor<Track>()) == 3)
    }
}
