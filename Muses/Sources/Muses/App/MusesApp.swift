import SwiftUI
import SwiftData

@main
struct MusesApp: App {
    let modelContainer: ModelContainer
    let libraryService: LibraryService
    let playbackService: PlaybackService
    private let nowPlayingManager: NowPlayingManager

    init() {
        let container = try! makeModelContainer()
        self.modelContainer = container
        let meta = MetadataService(artworkCache: .default)
        let library = LibraryService(modelContainer: container, metadata: meta)
        self.libraryService = library
        let engine = LocalAudioEngine()
        let queue = QueueService()
        queue.modelContext = container.mainContext
        queue.restore()
        self.playbackService = PlaybackService(engine: engine, queue: queue)
        let enricher = MetadataEnricherService(modelContainer: container)
        library.enricher = enricher
        self.nowPlayingManager = NowPlayingManager(playbackService)
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
