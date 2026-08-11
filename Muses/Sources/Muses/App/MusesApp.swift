import SwiftUI
import SwiftData

@main
struct MusesApp: App {
    let modelContainer: ModelContainer
    let libraryService: LibraryService
    let playbackService: PlaybackService

    init() {
        let container = try! makeModelContainer()
        self.modelContainer = container
        let meta = MetadataService(artworkCache: .default)
        self.libraryService = LibraryService(modelContainer: container, metadata: meta)
        let engine = LocalAudioEngine()
        let queue = QueueService()
        self.playbackService = PlaybackService(engine: engine, queue: queue)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(libraryService)
                .environment(playbackService)
                .modelContainer(modelContainer)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
    }
}
