import Foundation
import SwiftData

enum MusesSchema {
    static var v1: Schema {
        Schema([Track.self, Album.self, ScanRoot.self, QueueState.self, EQPreset.self,
                YouTubeImport.self, YouTubeImportItem.self,
                Playlist.self, PlaylistItem.self])
    }
}

func makeModelContainer(inMemory: Bool = false) throws -> ModelContainer {
    let config: ModelConfiguration
    if inMemory {
        config = ModelConfiguration(isStoredInMemoryOnly: true)
    } else {
        let url = URL.homeDirectory
            .appending(path: "Library/Application Support/Muses/muses.sqlite")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        config = ModelConfiguration(url: url)
    }
    return try ModelContainer(for: MusesSchema.v1, configurations: config)
}